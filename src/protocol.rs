// Line protocol between shell frontends and the daemon. Tab-separated fields,
// candidates joined with \x1f, candidate fields with \x1e. The free-text
// fields (buffer, cwd, cmd) escape backslash, tab and newline.

pub const CAND_SEP: char = '\u{1f}';
pub const FIELD_SEP: char = '\u{1e}';

#[derive(Debug, PartialEq)]
pub enum Request {
    Query { id: u64, cols: usize, cursor: usize, cwd: String, buffer: String },
    Lines { id: u64, cwd: String, buffer: String },
    Search { id: u64, limit: usize, cwd: String, query: String },
    Record { exit: i32, duration_ms: i64, cwd: String, cmd: String },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Source {
    History,
    Exec,
    File,
    Dir,
    Line,
}

impl Source {
    pub fn tag(self) -> &'static str {
        match self {
            Source::History => "hist",
            Source::Exec => "exec",
            Source::File => "file",
            Source::Dir => "dir",
            Source::Line => "line",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Candidate {
    pub text: String,
    pub source: Source,
    pub score: i64,
    // Char positions matched by the pattern, for highlighting in the search
    // UI. Empty for the inline word path.
    pub indices: Vec<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Multi,
    Single,
    None,
    Empty,
}

impl State {
    pub fn tag(self) -> &'static str {
        match self {
            State::Multi => "multi",
            State::Single => "single",
            State::None => "none",
            State::Empty => "empty",
        }
    }
}

pub struct Reply {
    pub id: u64,
    pub state: State,
    pub word_start: usize,
    pub total: usize,
    pub candidates: Vec<Candidate>,
}

impl Reply {
    pub fn format(&self) -> String {
        let cands: Vec<String> = self
            .candidates
            .iter()
            .map(|c| {
                let inds: Vec<String> = c.indices.iter().map(|i| i.to_string()).collect();
                format!(
                    "{}{}{}{}{}",
                    escape(&c.text),
                    FIELD_SEP,
                    c.source.tag(),
                    FIELD_SEP,
                    inds.join(",")
                )
            })
            .collect();
        format!(
            "R\t{}\t{}\t{}\t{}\t{}\n",
            self.id,
            self.state.tag(),
            self.word_start,
            self.total,
            cands.join(&CAND_SEP.to_string())
        )
    }
}

pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

pub fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('t') => out.push('\t'),
                Some('n') => out.push('\n'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn parse_request(line: &str) -> Option<Request> {
    let line = line.trim_end_matches('\n');
    let mut fields = line.split('\t');
    match fields.next()? {
        "Q" => {
            let id = fields.next()?.parse().ok()?;
            let cols = fields.next()?.parse().ok()?;
            let cursor = fields.next()?.parse().ok()?;
            let cwd = unescape(fields.next()?);
            let buffer = unescape(&fields.collect::<Vec<_>>().join("\t"));
            Some(Request::Query { id, cols, cursor, cwd, buffer })
        }
        "L" => {
            let id = fields.next()?.parse().ok()?;
            let cwd = unescape(fields.next()?);
            let buffer = unescape(&fields.collect::<Vec<_>>().join("\t"));
            Some(Request::Lines { id, cwd, buffer })
        }
        "S" => {
            let id = fields.next()?.parse().ok()?;
            let limit = fields.next()?.parse().ok()?;
            let cwd = unescape(fields.next()?);
            let query = unescape(&fields.collect::<Vec<_>>().join("\t"));
            Some(Request::Search { id, limit, cwd, query })
        }
        "H" => {
            let exit = fields.next()?.parse().ok()?;
            let duration_ms = fields.next()?.parse().ok()?;
            let cwd = unescape(fields.next()?);
            let cmd = unescape(&fields.collect::<Vec<_>>().join("\t"));
            Some(Request::Record { exit, duration_ms, cwd, cmd })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_roundtrip() {
        let raw = "echo \"a\tb\"\nls \\ x";
        assert_eq!(unescape(&escape(raw)), raw);
        assert!(!escape(raw).contains('\t'));
        assert!(!escape(raw).contains('\n'));
    }

    #[test]
    fn parse_query() {
        let req = parse_request("Q\t7\t120\t6\t/home/mt\tgit ch\n").unwrap();
        assert_eq!(
            req,
            Request::Query {
                id: 7,
                cols: 120,
                cursor: 6,
                cwd: "/home/mt".into(),
                buffer: "git ch".into()
            }
        );
    }

    #[test]
    fn parse_record_with_escapes() {
        let req = parse_request("H\t1\t250\t/tmp\techo \\ta\\nb").unwrap();
        assert_eq!(
            req,
            Request::Record {
                exit: 1,
                duration_ms: 250,
                cwd: "/tmp".into(),
                cmd: "echo \ta\nb".into()
            }
        );
    }
}
