use anyhow::{Context, Result};
use std::path::PathBuf;

pub fn queue_dir() -> Result<PathBuf> {
    let path = match std::env::var_os("RUST_PIXEL_QUEUE_DIR") {
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => dirs::data_dir()
            .context("Cannot locate the user data directory")?
            .join(".rust-pixel")
            .join("queue"),
    };
    Ok(std::path::absolute(path)?)
}

pub fn aseprite_dir() -> Result<PathBuf> {
    Ok(dirs::config_dir()
        .context("Cannot locate the user configuration directory")?
        .join(if cfg!(target_os = "windows") {
            "Aseprite"
        } else {
            "aseprite"
        }))
}

pub fn install_dir() -> Result<PathBuf> {
    Ok(dirs::data_local_dir()
        .context("Cannot locate the local application directory")?
        .join("Programs")
        .join("Rust Pixel Bridge"))
}
