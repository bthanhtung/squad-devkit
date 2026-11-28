use std::{env, path::PathBuf};

/// Return the first nonempty home directory environment variable.
pub fn home_dir() -> Option<PathBuf> {
    ["HOME", "USERPROFILE"]
        .into_iter()
        .find_map(|key| env::var_os(key).filter(|value| !value.is_empty()))
        .map(PathBuf::from)
}
