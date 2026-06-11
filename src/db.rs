use rusqlite::Connection;

pub struct HistRow {
    pub cmd: String,
    pub cwd: String,
    pub exit: i32,
    pub ts: i64,
}

pub fn open() -> rusqlite::Result<Connection> {
    let path = crate::paths::db_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         CREATE TABLE IF NOT EXISTS history (
             id INTEGER PRIMARY KEY,
             cmd TEXT NOT NULL,
             cwd TEXT NOT NULL DEFAULT '',
             exit INTEGER NOT NULL DEFAULT 0,
             duration_ms INTEGER NOT NULL DEFAULT 0,
             ts INTEGER NOT NULL,
             session TEXT NOT NULL DEFAULT ''
         );
         CREATE UNIQUE INDEX IF NOT EXISTS idx_history_dedup ON history(ts, cmd);",
    )?;
    Ok(conn)
}

pub fn insert(
    conn: &Connection,
    cmd: &str,
    cwd: &str,
    exit: i32,
    duration_ms: i64,
    ts: i64,
    session: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO history (cmd, cwd, exit, duration_ms, ts, session)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![cmd, cwd, exit, duration_ms, ts, session],
    )?;
    Ok(())
}

pub fn load_all(conn: &Connection) -> rusqlite::Result<Vec<HistRow>> {
    let mut stmt = conn.prepare("SELECT cmd, cwd, exit, ts FROM history ORDER BY ts")?;
    let rows = stmt.query_map([], |r| {
        Ok(HistRow { cmd: r.get(0)?, cwd: r.get(1)?, exit: r.get(2)?, ts: r.get(3)? })
    })?;
    rows.collect()
}
