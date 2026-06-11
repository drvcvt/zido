use crate::db::HistRow;
use crate::protocol::{Candidate, Reply, Source, State};
use crate::sources;
use nucleo_matcher::pattern::{AtomKind, CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

// The frontend scrolls through candidates with a moving selection block, so
// it needs the deep list, not just the visible window.
const MAX_CANDIDATES: usize = 100;
pub const LINES_LIMIT: usize = 20;
pub const SEARCH_LIMIT: usize = 50;

// Score weights. Nucleo scores land around 30-200 for short words; the
// context bonuses below are sized to reorder within similar match quality,
// not to override a clearly better match. Tuned live.
const W_MATCH: i64 = 4;
const W_PREFIX: i64 = 300;
const W_EXACT: i64 = 500;
const W_FREC: f64 = 25.0;
const W_CWD: i64 = 80;
const W_SAME_CMD: i64 = 60;
const W_FAIL: i64 = -50;

#[derive(Default)]
struct TokenStat {
    count: u32,
    last_ts: i64,
}

struct Entry {
    cmd: String,
    cwd: String,
    exit: i32,
    ts: i64,
}

pub struct Index {
    entries: Vec<Entry>,
    tokens: HashMap<String, TokenStat>,
    first_tokens: HashMap<String, TokenStat>,
    token_cwd: HashMap<(String, String), u32>,
    token_cmd: HashMap<(String, String), u32>,
    execs: Vec<String>,
    now: fn() -> i64,
}

fn real_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Index {
    pub fn new(rows: Vec<HistRow>, execs: Vec<String>) -> Self {
        let mut idx = Index {
            entries: Vec::with_capacity(rows.len()),
            tokens: HashMap::new(),
            first_tokens: HashMap::new(),
            token_cwd: HashMap::new(),
            token_cmd: HashMap::new(),
            execs,
            now: real_now,
        };
        for row in rows {
            idx.record(&row.cmd, &row.cwd, row.exit, row.ts);
        }
        idx
    }

    pub fn record(&mut self, cmd: &str, cwd: &str, exit: i32, ts: i64) {
        let words: Vec<&str> = cmd.split_whitespace().collect();
        if words.is_empty() {
            return;
        }
        let first = words[0].to_string();
        if indexable_token(&first) {
            bump(&mut self.first_tokens, &first, ts);
        }
        for w in &words {
            if !indexable_token(w) {
                continue;
            }
            bump(&mut self.tokens, w, ts);
            *self
                .token_cwd
                .entry((w.to_string(), cwd.to_string()))
                .or_insert(0) += 1;
            *self
                .token_cmd
                .entry((w.to_string(), first.clone()))
                .or_insert(0) += 1;
        }
        self.entries.push(Entry {
            cmd: cmd.to_string(),
            cwd: cwd.to_string(),
            exit,
            ts,
        });
    }

    fn frecency(&self, stat: &TokenStat) -> i64 {
        let age_days = ((self.now)() - stat.last_ts).max(0) as f64 / 86_400.0;
        let decay = 0.5_f64.powf(age_days / 30.0);
        ((1.0 + stat.count as f64).ln() * decay * W_FREC) as i64
    }

    pub fn query_word(&self, id: u64, buffer: &str, cursor: usize, cwd: &str) -> Reply {
        let chars: Vec<char> = buffer.chars().collect();
        let cursor = cursor.min(chars.len());
        let mut ws = cursor;
        while ws > 0 && !chars[ws - 1].is_whitespace() {
            ws -= 1;
        }
        let word: String = chars[ws..cursor].iter().collect();
        let before: String = chars[..ws].iter().collect();
        let is_first = before.split_whitespace().next().is_none();

        if word.is_empty() {
            return self.predict_next(id, &before, cursor, cwd);
        }

        let first_word = before.split_whitespace().next().unwrap_or("").to_string();
        let mut raw: Vec<Candidate> = Vec::new();
        let mut word_start = ws;

        if word.contains('/') || word.starts_with('~') {
            let (files, seg_start) = sources::file_candidates(&word, cwd);
            raw = files;
            word_start = ws + seg_start;
        } else if is_first {
            for e in &self.execs {
                raw.push(Candidate { text: e.clone(), source: Source::Exec, score: 0, indices: vec![] });
            }
            for (t, _) in self.first_tokens.iter() {
                raw.push(Candidate { text: t.clone(), source: Source::History, score: 0, indices: vec![] });
            }
        } else {
            for (t, _) in self.tokens.iter() {
                raw.push(Candidate { text: t.clone(), source: Source::History, score: 0, indices: vec![] });
            }
            let (files, _) = sources::file_candidates(&word, cwd);
            raw.extend(files);
        }

        // The match needle is the replaceable segment (basename for paths).
        let needle: String = chars[word_start..cursor].iter().collect();
        let ranked = self.rank(&needle, raw, cwd, &first_word);
        let mut total = ranked.len();
        let mut candidates: Vec<Candidate> = ranked.into_iter().take(MAX_CANDIDATES).collect();

        // History tokens that name an existing directory must complete like
        // one (trailing slash, no space on accept) — otherwise `cd ba` ⇥
        // yields "bash " with a dead space instead of "bash-kurs/".
        pathify(&mut candidates, cwd);
        if dir_context(&first_word) {
            candidates.retain(|c| c.source == Source::Dir);
            total = candidates.len();
        }

        let state = match candidates.len() {
            0 => State::None,
            1 => State::Single,
            _ => State::Multi,
        };
        Reply { id, state, word_start, total, candidates }
    }

    // Next-word prediction when the cursor sits after whitespace: look at
    // history lines whose leading tokens equal the tokens typed so far and
    // count what came next.
    fn predict_next(&self, id: u64, before: &str, cursor: usize, cwd: &str) -> Reply {
        let prefix: Vec<&str> = before.split_whitespace().collect();
        let empty = Reply { id, state: State::Empty, word_start: cursor, total: 0, candidates: vec![] };
        if prefix.is_empty() {
            return empty;
        }
        let now = (self.now)();
        let mut next: HashMap<&str, (u32, i64)> = HashMap::new();
        for e in &self.entries {
            let toks: Vec<&str> = e.cmd.split_whitespace().collect();
            if toks.len() <= prefix.len() || toks[..prefix.len()] != prefix[..] {
                continue;
            }
            if !indexable_token(toks[prefix.len()]) {
                continue;
            }
            let ent = next.entry(toks[prefix.len()]).or_insert((0, 0));
            ent.0 += 1;
            if e.ts > ent.1 {
                ent.1 = e.ts;
            }
            if e.cwd == cwd {
                ent.0 += 2;
            }
        }
        let mut cands: Vec<Candidate> = next
            .into_iter()
            .map(|(t, (count, last_ts))| {
                let age_days = (now - last_ts).max(0) as f64 / 86_400.0;
                let decay = 0.5_f64.powf(age_days / 30.0);
                Candidate {
                    text: t.to_string(),
                    source: Source::History,
                    score: ((1.0 + count as f64).ln() * decay * W_FREC) as i64,
                    indices: vec![],
                }
            })
            .collect();
        pathify(&mut cands, cwd);
        if dir_context(prefix[0]) {
            // After `cd ` the local directories are candidates even without
            // history evidence; history-backed ones keep their higher score.
            let (files, _) = sources::file_candidates("", cwd);
            for f in files {
                if f.source == Source::Dir && !cands.iter().any(|c| c.text == f.text) {
                    cands.push(Candidate { text: f.text, source: Source::Dir, score: 1, indices: vec![] });
                }
            }
            cands.retain(|c| c.source == Source::Dir);
        }
        cands.sort_by(|a, b| b.score.cmp(&a.score).then(a.text.cmp(&b.text)));
        let total = cands.len();
        cands.truncate(MAX_CANDIDATES);
        let state = match cands.len() {
            0 => State::Empty,
            1 => State::Single,
            _ => State::Multi,
        };
        Reply { id, state, word_start: cursor, total, candidates: cands }
    }

    fn rank(&self, needle: &str, raw: Vec<Candidate>, cwd: &str, first_word: &str) -> Vec<Candidate> {
        let mut matcher = Matcher::new(Config::DEFAULT);
        let pattern = Pattern::new(needle, CaseMatching::Smart, Normalization::Smart, AtomKind::Fuzzy);
        let needle_lc = needle.to_lowercase();
        // A needle without any alphanumeric chars ("[", "--", "./") fuzzy-
        // matches every token containing those chars — pure noise. Require a
        // prefix match in that case.
        let needle_alnum = needle.chars().any(|c| c.is_alphanumeric());
        let mut buf = Vec::new();

        let mut best: HashMap<String, Candidate> = HashMap::new();
        for mut cand in raw {
            let trimmed = cand.text.trim_end_matches('/');
            let Some(mscore) = pattern.score(Utf32Str::new(trimmed, &mut buf), &mut matcher) else {
                continue;
            };
            let mut score = mscore as i64 * W_MATCH;
            let text_lc = trimmed.to_lowercase();
            if !needle_alnum && !text_lc.starts_with(&needle_lc) {
                continue;
            }
            if text_lc == needle_lc {
                score += W_EXACT;
            } else if text_lc.starts_with(&needle_lc) {
                score += W_PREFIX;
            }
            // Shorter candidates win ties: closer to what was typed.
            score -= trimmed.chars().count() as i64;
            if cand.source == Source::History {
                if let Some(stat) = self.tokens.get(trimmed).or_else(|| self.tokens.get(&cand.text)) {
                    score += self.frecency(stat);
                }
                if self.token_cwd.contains_key(&(cand.text.clone(), cwd.to_string()))
                    || self.token_cwd.contains_key(&(trimmed.to_string(), cwd.to_string()))
                {
                    score += W_CWD;
                }
                if !first_word.is_empty()
                    && self.token_cmd.contains_key(&(cand.text.clone(), first_word.to_string()))
                {
                    score += W_SAME_CMD;
                }
            }
            cand.score = score;
            match best.get(cand.text.trim_end_matches('/')) {
                Some(prev) if prev.score >= cand.score => {}
                _ => {
                    best.insert(cand.text.trim_end_matches('/').to_string(), cand);
                }
            }
        }
        let mut out: Vec<Candidate> = best.into_values().collect();
        out.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then(a.text.len().cmp(&b.text.len()))
                .then(a.text.cmp(&b.text))
        });
        out
    }

    pub fn query_lines(&self, id: u64, buffer: &str, cwd: &str, limit: usize) -> Reply {
        let needle = buffer.trim();
        let mut matcher = Matcher::new(Config::DEFAULT);
        let pattern = Pattern::new(needle, CaseMatching::Smart, Normalization::Smart, AtomKind::Fuzzy);
        let now = (self.now)();
        let mut buf = Vec::new();

        struct LineStat {
            count: u32,
            last_ts: i64,
            fails: u32,
            in_cwd: bool,
        }
        let mut lines: HashMap<&str, LineStat> = HashMap::new();
        for e in &self.entries {
            if e.cmd.chars().any(|c| c.is_control() && c != '\n' && c != '\t') {
                continue;
            }
            let s = lines.entry(e.cmd.as_str()).or_insert(LineStat {
                count: 0,
                last_ts: 0,
                fails: 0,
                in_cwd: false,
            });
            s.count += 1;
            s.last_ts = s.last_ts.max(e.ts);
            if e.exit != 0 {
                s.fails += 1;
            }
            if e.cwd == cwd {
                s.in_cwd = true;
            }
        }

        let mut cands: Vec<Candidate> = Vec::new();
        for (cmd, s) in lines {
            let mscore = if needle.is_empty() {
                0
            } else {
                match pattern.score(Utf32Str::new(cmd, &mut buf), &mut matcher) {
                    Some(m) => m as i64 * W_MATCH,
                    None => continue,
                }
            };
            let age_days = (now - s.last_ts).max(0) as f64 / 86_400.0;
            let decay = 0.5_f64.powf(age_days / 30.0);
            let mut score = mscore + ((1.0 + s.count as f64).ln() * decay * W_FREC) as i64;
            if s.in_cwd {
                score += W_CWD;
            }
            if s.fails * 2 > s.count {
                score += W_FAIL;
            }
            if !needle.is_empty() && cmd.to_lowercase().starts_with(&needle.to_lowercase()) {
                score += W_PREFIX;
            }
            cands.push(Candidate { text: cmd.to_string(), source: Source::Line, score, indices: vec![] });
        }
        cands.sort_by(|a, b| b.score.cmp(&a.score).then(a.text.cmp(&b.text)));
        let total = cands.len();
        cands.truncate(limit);
        // Match positions only for the survivors — the search UI highlights
        // them; computing indices for every history line would be waste.
        if !needle.is_empty() {
            for c in cands.iter_mut() {
                let mut inds: Vec<u32> = Vec::new();
                if pattern
                    .indices(Utf32Str::new(&c.text, &mut buf), &mut matcher, &mut inds)
                    .is_some()
                {
                    inds.sort_unstable();
                    inds.dedup();
                    c.indices = inds;
                }
            }
        }
        let state = if cands.is_empty() { State::Empty } else { State::Multi };
        Reply { id, state, word_start: 0, total, candidates: cands }
    }
}

// Commands whose arguments are directories: only Dir candidates make sense.
// `z` is the user-facing zoxide alias for cd.
fn dir_context(first_word: &str) -> bool {
    matches!(first_word, "cd" | "z" | "pushd" | "rmdir")
}

// Upgrade history tokens that name an existing directory to Dir candidates
// (trailing slash → the frontend appends no space on accept).
fn pathify(cands: &mut [Candidate], cwd: &str) {
    for c in cands.iter_mut() {
        if c.source != Source::History {
            continue;
        }
        // History tokens recorded WITH a trailing slash ("cd bash-kurs/")
        // must upgrade too, or directory-only contexts drop them.
        let trimmed = c.text.trim_end_matches('/');
        let Some(p) = resolve_for_stat(trimmed, cwd) else { continue };
        if std::fs::metadata(&p).map(|m| m.is_dir()).unwrap_or(false) {
            if !c.text.ends_with('/') {
                c.text.push('/');
            }
            c.source = Source::Dir;
        }
    }
}

fn resolve_for_stat(text: &str, cwd: &str) -> Option<PathBuf> {
    if text.starts_with('-') {
        return None;
    }
    Some(if let Some(rest) = text.strip_prefix("~/") {
        crate::paths::home().join(rest)
    } else if text == "~" {
        crate::paths::home()
    } else if text.starts_with('/') {
        PathBuf::from(text)
    } else {
        Path::new(cwd).join(text)
    })
}

// Tokens that should never appear as inline candidates: anything overly long
// (base64 blobs, JWTs — fuzzy matching finds garbage subsequences in those)
// and values of secret-looking VAR=... assignments.
fn indexable_token(t: &str) -> bool {
    if t.chars().count() > 48 {
        return false;
    }
    // Paste markers (ESC[200~) and other control chars from old history
    // entries must never surface as candidates.
    if t.chars().any(|c| c.is_control()) {
        return false;
    }
    if let Some((name, value)) = t.split_once('=') {
        let name_uc = name.to_uppercase();
        let secret_name = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY"]
            .iter()
            .any(|p| name_uc.contains(p));
        if secret_name && !value.is_empty() {
            return false;
        }
        if name_uc == name && value.len() > 16 {
            return false;
        }
    }
    true
}

fn bump(map: &mut HashMap<String, TokenStat>, key: &str, ts: i64) {
    let stat = map.entry(key.to_string()).or_default();
    stat.count += 1;
    stat.last_ts = stat.last_ts.max(ts);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now_fixed() -> i64 {
        2_000_000_000
    }

    fn test_index(cmds: &[(&str, &str, i32)]) -> Index {
        let rows: Vec<HistRow> = cmds
            .iter()
            .map(|(cmd, cwd, exit)| HistRow {
                cmd: cmd.to_string(),
                cwd: cwd.to_string(),
                exit: *exit,
                ts: now_fixed() - 3600,
            })
            .collect();
        let mut idx = Index::new(rows, vec!["cargo".into(), "cat".into(), "git".into()]);
        idx.now = now_fixed;
        idx
    }

    #[test]
    fn first_word_prefix_beats_fuzzy() {
        let idx = test_index(&[("git status", "/p", 0)]);
        let r = idx.query_word(1, "ca", 2, "/p");
        assert_eq!(r.state, State::Multi);
        assert_eq!(r.candidates[0].text, "cat");
        assert!(r.candidates.iter().any(|c| c.text == "cargo"));
    }

    #[test]
    fn history_arg_tokens_match() {
        let idx = test_index(&[
            ("git checkout main", "/p", 0),
            ("git checkout main", "/p", 0),
            ("git cherry-pick abc", "/p", 0),
        ]);
        let r = idx.query_word(1, "git ch", 6, "/p");
        assert_eq!(r.word_start, 4);
        assert_eq!(r.candidates[0].text, "checkout");
    }

    #[test]
    fn next_word_prediction() {
        let idx = test_index(&[
            ("git checkout main", "/p", 0),
            ("git checkout main", "/p", 0),
            ("git checkout dev", "/x", 0),
        ]);
        let r = idx.query_word(1, "git checkout ", 13, "/p");
        assert_eq!(r.state, State::Multi);
        assert_eq!(r.candidates[0].text, "main");
        assert_eq!(r.word_start, 13);
    }

    #[test]
    fn single_match_state() {
        let idx = test_index(&[("rsync -av a b", "/p", 0)]);
        let r = idx.query_word(1, "rsy", 3, "/p");
        assert_eq!(r.state, State::Single);
        assert_eq!(r.candidates[0].text, "rsync");
    }

    #[test]
    fn no_match_state() {
        let idx = test_index(&[("git status", "/p", 0)]);
        let r = idx.query_word(1, "qqqqzz", 6, "/p");
        assert_eq!(r.state, State::None);
    }

    #[test]
    fn empty_buffer_is_empty_state() {
        let idx = test_index(&[("git status", "/p", 0)]);
        let r = idx.query_word(1, "", 0, "/p");
        assert_eq!(r.state, State::Empty);
    }

    #[test]
    fn secrets_and_blobs_not_indexed() {
        let idx = test_index(&[
            ("export N8N_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef", "/p", 0),
            ("MY_PASSWORD=hunter2 ./run", "/p", 0),
        ]);
        let r = idx.query_word(1, "vim qqqzz", 9, "/p");
        assert_eq!(r.state, State::None);
        let r = idx.query_word(1, "echo hunter", 11, "/p");
        assert!(r.candidates.iter().all(|c| c.text != "MY_PASSWORD=hunter2"));
    }

    fn pathify_fixture() -> String {
        let base = std::env::temp_dir().join("klammer-test-pathify");
        let _ = std::fs::create_dir_all(base.join("bash-kurs"));
        let _ = std::fs::create_dir_all(base.join("projects"));
        let _ = std::fs::write(base.join("notes.txt"), "x");
        base.to_str().unwrap().to_string()
    }

    #[test]
    fn history_dir_tokens_complete_as_dirs() {
        let cwd = pathify_fixture();
        let idx = test_index(&[("cd bash-kurs", &cwd, 0), ("cat notes.txt", &cwd, 0)]);
        let r = idx.query_word(1, "cd ba", 5, &cwd);
        assert!(!r.candidates.is_empty());
        assert_eq!(r.candidates[0].text, "bash-kurs/");
        assert!(r.candidates.iter().all(|c| c.text.ends_with('/')), "cd must only offer dirs");
    }

    #[test]
    fn slash_history_tokens_survive_dir_context() {
        let cwd = pathify_fixture();
        let idx = test_index(&[("cd bash-kurs/", &cwd, 0)]);
        let r = idx.query_word(1, "cd ba", 5, &cwd);
        assert!(
            r.candidates.iter().any(|c| c.text == "bash-kurs/"),
            "got: {:?}",
            r.candidates.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn cd_predicts_local_dirs_without_history() {
        let cwd = pathify_fixture();
        let idx = test_index(&[("echo x", &cwd, 0)]);
        let r = idx.query_word(1, "cd ", 3, &cwd);
        assert!(r.candidates.iter().any(|c| c.text == "bash-kurs/"));
        assert!(r.candidates.iter().all(|c| c.text.ends_with('/')));
    }

    #[test]
    fn non_dir_commands_keep_files() {
        let cwd = pathify_fixture();
        let idx = test_index(&[("cat notes.txt", &cwd, 0)]);
        let r = idx.query_word(1, "cat no", 6, &cwd);
        assert!(r.candidates.iter().any(|c| c.text == "notes.txt"));
    }

    #[test]
    fn control_char_first_tokens_not_indexed() {
        let idx = test_index(&[("\u{1b}[200~cd /tmp", "/p", 0), ("cargo build", "/p", 0)]);
        let r = idx.query_word(1, "c", 1, "/p");
        assert!(r.candidates.iter().all(|c| !c.text.contains('\u{1b}')));
    }

    #[test]
    fn punctuation_needle_requires_prefix() {
        let idx = test_index(&[("[ -f x ]", "/p", 0), ("echo a[b]c", "/p", 0)]);
        let r = idx.query_word(1, "test [", 6, "/p");
        assert!(
            r.candidates.iter().all(|c| c.text.starts_with('[')),
            "got: {:?}",
            r.candidates.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn search_returns_match_indices() {
        let idx = test_index(&[("cargo build --release", "/p", 0)]);
        let r = idx.query_lines(1, "crgo", "/p", SEARCH_LIMIT);
        assert!(!r.candidates.is_empty());
        let c = &r.candidates[0];
        assert!(!c.indices.is_empty());
        // every reported index points at a char from the needle
        for &i in &c.indices {
            let ch = c.text.chars().nth(i as usize).unwrap();
            assert!("crgo".contains(ch), "index {i} -> '{ch}'");
        }
    }

    #[test]
    fn lines_rank_frequency_and_cwd() {
        let idx = test_index(&[
            ("cargo build", "/p", 0),
            ("cargo build", "/p", 0),
            ("cargo test", "/other", 0),
        ]);
        let r = idx.query_lines(1, "car", "/p", LINES_LIMIT);
        assert_eq!(r.candidates[0].text, "cargo build");
    }

    #[test]
    fn failing_lines_rank_down() {
        let idx = test_index(&[
            ("make broken", "/p", 2),
            ("make broken", "/p", 2),
            ("make all", "/p", 0),
            ("make all", "/p", 0),
        ]);
        let r = idx.query_lines(1, "make", "/p", LINES_LIMIT);
        assert_eq!(r.candidates[0].text, "make all");
    }
}
