use crate::{db, paths};
use rusqlite::Connection;

pub fn run() {
    let conn = match db::open() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cannot open history db: {e}");
            std::process::exit(1);
        }
    };
    let mut total = 0usize;

    let atuin_db = paths::home().join(".local/share/atuin/history.db");
    if atuin_db.exists() {
        match import_atuin(&conn, &atuin_db) {
            Ok(n) => {
                println!("atuin: imported {n} entries");
                total += n;
            }
            Err(e) => eprintln!("atuin import failed: {e}"),
        }
    }

    let zsh_hist = std::env::var("HISTFILE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| paths::home().join(".zsh_history"));
    if zsh_hist.exists() {
        match import_zsh_history(&conn, &zsh_hist) {
            Ok(n) => {
                println!("zsh_history: imported {n} entries");
                total += n;
            }
            Err(e) => eprintln!("zsh_history import failed: {e}"),
        }
    }

    println!("done, {total} entries imported (duplicates ignored)");
}

fn import_atuin(conn: &Connection, path: &std::path::Path) -> rusqlite::Result<usize> {
    let src = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let mut stmt = src.prepare(
        "SELECT command, cwd, exit, timestamp, duration FROM history
         WHERE deleted_at IS NULL",
    )?;
    let rows = stmt.query_map([], |r| {
        let cmd: String = r.get(0)?;
        let cwd: String = r.get(1)?;
        let exit: i64 = r.get(2)?;
        let ts_nanos: i64 = r.get(3)?;
        let dur_nanos: i64 = r.get(4).unwrap_or(0);
        Ok((cmd, cwd, exit as i32, ts_nanos / 1_000_000_000, dur_nanos / 1_000_000))
    })?;
    let mut n = 0;
    conn.execute_batch("BEGIN")?;
    for row in rows.flatten() {
        let (cmd, cwd, exit, ts, dur_ms) = row;
        if cmd.trim().is_empty() {
            continue;
        }
        db::insert(conn, cmd.trim(), &cwd, exit, dur_ms, ts, "atuin-import")?;
        n += 1;
    }
    conn.execute_batch("COMMIT")?;
    Ok(n)
}

fn import_zsh_history(conn: &Connection, path: &std::path::Path) -> rusqlite::Result<usize> {
    let bytes = std::fs::read(path).map_err(|e| {
        rusqlite::Error::ToSqlConversionFailure(Box::new(e))
    })?;
    let text = String::from_utf8_lossy(&unmetafy(&bytes)).into_owned();
    let mut n = 0;
    conn.execute_batch("BEGIN")?;
    for (ts, cmd) in parse_zsh_history(&text) {
        if cmd.trim().is_empty() {
            continue;
        }
        db::insert(conn, cmd.trim(), "", 0, 0, ts, "zsh-import")?;
        n += 1;
    }
    conn.execute_batch("COMMIT")?;
    Ok(n)
}

// zsh metafies bytes >= 0x83 in the histfile: Meta (0x83) followed by the
// original byte XOR 0x20.
fn unmetafy(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x83 && i + 1 < bytes.len() {
            out.push(bytes[i + 1] ^ 0x20);
            i += 2;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    out
}

// EXTENDED_HISTORY format: `: <ts>:<dur>;<cmd>`. Lines not starting with that
// prefix are continuations of a multiline command.
fn parse_zsh_history(text: &str) -> Vec<(i64, String)> {
    let mut out: Vec<(i64, String)> = Vec::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix(": ") {
            if let Some((meta, cmd)) = rest.split_once(';') {
                let ts = meta
                    .split(':')
                    .next()
                    .and_then(|t| t.trim().parse().ok())
                    .unwrap_or(0);
                out.push((ts, cmd.trim_end_matches('\\').to_string()));
                continue;
            }
        }
        if let Some(last) = out.last_mut() {
            last.1.push('\n');
            last.1.push_str(line.trim_end_matches('\\'));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_extended_history() {
        let text = ": 1700000000:0;git status\n: 1700000001:2;echo foo \\\nbar\n";
        let entries = parse_zsh_history(text);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0], (1700000000, "git status".to_string()));
        assert_eq!(entries[1].1, "echo foo \nbar");
    }

    #[test]
    fn unmetafy_roundtrip() {
        // 0x83 0xC3^0x20 encodes 0xC3 (start of a UTF-8 umlaut).
        let metafied = vec![b'l', b's', b' ', 0x83, 0xc3 ^ 0x20, 0xa4];
        let plain = unmetafy(&metafied);
        assert_eq!(plain, vec![b'l', b's', b' ', 0xc3, 0xa4]);
        assert_eq!(String::from_utf8_lossy(&plain), "ls ä");
    }
}
