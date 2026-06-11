mod db;
mod import;
mod index;
mod paths;
mod protocol;
mod server;
mod sources;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(|s| s.as_str()) {
        Some("daemon") => server::run(),
        Some("init") => match args.get(1).map(|s| s.as_str()) {
            Some("zsh") => print_init_zsh(),
            _ => die("usage: klammer init zsh"),
        },
        Some("import") => import::run(),
        Some("gc") => gc(),
        Some("query") => debug_query(&args[1..]),
        Some("--version") | Some("-V") => println!("klammer {}", env!("CARGO_PKG_VERSION")),
        _ => die("usage: klammer <daemon|init zsh|import|gc|query BUFFER>"),
    }
}

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(2);
}

fn print_init_zsh() {
    let script = include_str!("../shell/init.zsh");
    let bin = std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(String::from))
        .unwrap_or_else(|| "klammer".into());
    print!("{}", script.replace("@KLAMMER_BIN@", &bin));
}

// Removes history rows containing escape sequences / control chars (old paste
// markers, pty test residue). Restart the daemon afterwards to drop the
// in-memory copies.
fn gc() {
    let conn = match db::open() {
        Ok(c) => c,
        Err(e) => die(&format!("cannot open history db: {e}")),
    };
    let mut stmt = conn.prepare("SELECT id, cmd FROM history").unwrap();
    let ids: Vec<i64> = stmt
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
        .unwrap()
        .flatten()
        .filter(|(_, cmd)| {
            cmd.chars().any(|c| c.is_control() && c != '\n' && c != '\t')
                || cmd.split_whitespace().any(is_escape_residue)
        })
        .map(|(id, _)| id)
        .collect();
    drop(stmt);
    for chunk in ids.chunks(500) {
        let list: Vec<String> = chunk.iter().map(|i| i.to_string()).collect();
        let _ = conn.execute(
            &format!("DELETE FROM history WHERE id IN ({})", list.join(",")),
            [],
        );
    }
    println!("removed {} polluted history rows", ids.len());
}

// Tokens left behind when a terminal stripped the ESC from an escape
// sequence: "[A".."[D" (arrows), "[200~"/"[201~" (paste markers), "[1;5C"
// style modifiers.
fn is_escape_residue(t: &str) -> bool {
    let Some(rest) = t.strip_prefix('[') else { return false };
    if rest.len() == 1 && rest.chars().all(|c| c.is_ascii_uppercase()) {
        return true;
    }
    let body: String = rest.chars().take_while(|c| c.is_ascii_digit() || *c == ';').collect();
    !body.is_empty() && rest[body.len()..].starts_with(['~', 'A', 'B', 'C', 'D'])
}

// One-shot query against a running daemon, for debugging and smoke tests.
fn debug_query(args: &[String]) {
    let buffer = args.join(" ");
    let cwd = std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let sock = paths::socket_path();
    let mut stream = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(e) => die(&format!("cannot connect to daemon at {}: {e}", sock.display())),
    };
    let cursor = buffer.chars().count();
    let req = format!(
        "Q\t1\t120\t{}\t{}\t{}\n",
        cursor,
        protocol::escape(&cwd),
        protocol::escape(&buffer)
    );
    stream.write_all(req.as_bytes()).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    let fields: Vec<&str> = line.trim_end().splitn(6, '\t').collect();
    if fields.len() < 5 {
        die(&format!("bad response: {line}"));
    }
    // Single buffered write with errors ignored: `klammer query | head`
    // must not panic on SIGPIPE.
    let mut out = format!(
        "state={} word_start={} total={}\n",
        fields[2], fields[3], fields[4]
    );
    if let Some(cands) = fields.get(5) {
        for c in cands.split('\u{1f}').filter(|c| !c.is_empty()) {
            let mut parts = c.split('\u{1e}');
            let text = parts.next().unwrap_or("");
            let source = parts.next().unwrap_or("");
            out.push_str(&format!("  {text}  ({source})\n"));
        }
    }
    let _ = std::io::stdout().write_all(out.as_bytes());
}
