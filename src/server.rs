use crate::protocol::{parse_request, Request};
use crate::{db, index, paths, sources};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

struct State {
    index: index::Index,
    conn: rusqlite::Connection,
    session_counter: u64,
}

pub fn run() {
    let sock = paths::socket_path();
    if UnixStream::connect(&sock).is_ok() {
        eprintln!("klammer daemon already running at {}", sock.display());
        return;
    }
    let _ = std::fs::remove_file(&sock);

    let conn = match db::open() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cannot open history db: {e}");
            std::process::exit(1);
        }
    };
    let rows = db::load_all(&conn).unwrap_or_default();
    let execs = sources::scan_path_execs();
    eprintln!(
        "klammer daemon: {} history entries, {} executables",
        rows.len(),
        execs.len()
    );
    let state = Arc::new(Mutex::new(State {
        index: index::Index::new(rows, execs),
        conn,
        session_counter: 0,
    }));

    let listener = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cannot bind {}: {e}", sock.display());
            std::process::exit(1);
        }
    };

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let state = Arc::clone(&state);
        std::thread::spawn(move || handle(stream, state));
    }
}

fn handle(stream: UnixStream, state: Arc<Mutex<State>>) {
    let mut writer = match stream.try_clone() {
        Ok(w) => w,
        Err(_) => return,
    };
    let session = {
        let mut s = state.lock().unwrap();
        s.session_counter += 1;
        format!("s{}", s.session_counter)
    };
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        let Some(req) = parse_request(&line) else { continue };
        match req {
            Request::Query { id, cols: _, cursor, cwd, buffer } => {
                let reply = state.lock().unwrap().index.query_word(id, &buffer, cursor, &cwd);
                if writer.write_all(reply.format().as_bytes()).is_err() {
                    break;
                }
            }
            Request::Lines { id, cwd, buffer } => {
                let reply = state.lock().unwrap().index.query_lines(id, &buffer, &cwd);
                if writer.write_all(reply.format().as_bytes()).is_err() {
                    break;
                }
            }
            Request::Record { exit, duration_ms, cwd, cmd } => {
                let cmd = cmd.trim();
                if cmd.is_empty() {
                    continue;
                }
                // Escape sequences (paste markers, arrow-key residue from
                // scripted ptys) must never enter the history db.
                if cmd.chars().any(|c| c.is_control() && c != '\n' && c != '\t') {
                    continue;
                }
                let ts = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                let mut s = state.lock().unwrap();
                let _ = db::insert(&s.conn, cmd, &cwd, exit, duration_ms, ts, &session);
                s.index.record(cmd, &cwd, exit, ts);
            }
        }
    }
}
