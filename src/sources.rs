use crate::protocol::{Candidate, Source};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const DIR_SCAN_CAP: usize = 5000;

// Executables in $PATH, scanned once at daemon start.
pub fn scan_path_execs() -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let path = std::env::var("PATH").unwrap_or_default();
    for dir in path.split(':').filter(|d| !d.is_empty()) {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        for entry in entries.flatten() {
            let Ok(name) = entry.file_name().into_string() else { continue };
            if seen.contains(&name) {
                continue;
            }
            let is_exec = entry
                .metadata()
                .map(|m| m.is_file() || m.is_symlink())
                .unwrap_or(false);
            if is_exec {
                seen.insert(name.clone());
                out.push(name);
            }
        }
    }
    out.sort();
    out
}

// File/dir candidates for `word` relative to `cwd`. Returns the candidates and
// the char offset within the word where the replaceable segment starts (after
// the last '/'). Directory candidates end with '/'.
pub fn file_candidates(word: &str, cwd: &str) -> (Vec<Candidate>, usize) {
    let (dir_part, _seg) = match word.rfind('/') {
        Some(i) => (&word[..=i], &word[i + 1..]),
        None => ("", word),
    };
    let seg_start_chars = dir_part.chars().count();

    let base: PathBuf = if let Some(rest) = dir_part.strip_prefix("~/") {
        crate::paths::home().join(rest)
    } else if dir_part == "~" {
        crate::paths::home()
    } else if dir_part.starts_with('/') {
        PathBuf::from(dir_part)
    } else {
        Path::new(cwd).join(dir_part)
    };

    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&base) else {
        return (out, seg_start_chars);
    };
    for entry in entries.flatten().take(DIR_SCAN_CAP) {
        let Ok(mut name) = entry.file_name().into_string() else { continue };
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        let source = if is_dir { Source::Dir } else { Source::File };
        if is_dir {
            name.push('/');
        }
        out.push(Candidate { text: name, source, score: 0, indices: vec![] });
    }
    (out, seg_start_chars)
}
