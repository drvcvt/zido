use std::path::PathBuf;

pub fn socket_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(dir).join("klammer.sock");
    }
    let uid = libc_getuid();
    PathBuf::from(format!("/tmp/klammer-{uid}.sock"))
}

pub fn data_dir() -> PathBuf {
    let base = std::env::var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".local/share"));
    base.join("klammer")
}

pub fn db_path() -> PathBuf {
    data_dir().join("history.db")
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

fn libc_getuid() -> u32 {
    // std exposes no getuid; reading /proc avoids a libc dependency for the
    // rare no-XDG_RUNTIME_DIR fallback.
    std::fs::read_to_string("/proc/self/loginuid")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}
