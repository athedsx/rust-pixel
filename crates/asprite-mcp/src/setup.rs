use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

const PLUGIN_FILES: &[(&str, &str)] = &[
    ("LICENSE", include_str!("../../../LICENSE")),
    (
        "package.json",
        include_str!("../../../aseprite-plugin/package.json"),
    ),
    (
        "init.lua",
        include_str!("../../../aseprite-plugin/init.lua"),
    ),
    (
        "bridge.lua",
        include_str!("../../../aseprite-plugin/bridge.lua"),
    ),
    (
        "panel.lua",
        include_str!("../../../aseprite-plugin/panel.lua"),
    ),
    ("ui.lua", include_str!("../../../aseprite-plugin/ui.lua")),
    (
        "panel-view.lua",
        include_str!("../../../aseprite-plugin/panel-view.lua"),
    ),
];

struct Options {
    install_dir: PathBuf,
    aseprite_dir: PathBuf,
    claude_config: Option<PathBuf>,
}

impl Options {
    fn parse(args: impl Iterator<Item = OsString>) -> Result<Self> {
        let mut aseprite_explicit = false;
        let current_dir = std::env::current_exe()?
            .parent()
            .context("Cannot locate executable directory")?
            .to_path_buf();
        let mut options = Self {
            install_dir: if current_dir.join("installation.json").is_file() {
                current_dir
            } else {
                crate::config::install_dir()?
            },
            aseprite_dir: crate::config::aseprite_dir()?,
            claude_config: None,
        };
        let mut args = args;
        while let Some(arg) = args.next() {
            match arg.to_str() {
                Some("--install-dir") => {
                    options.install_dir =
                        PathBuf::from(args.next().context("--install-dir requires a path")?)
                }
                Some("--aseprite-dir") => {
                    aseprite_explicit = true;
                    options.aseprite_dir =
                        PathBuf::from(args.next().context(
                            "--aseprite-dir requires the Aseprite configuration directory",
                        )?)
                }
                Some("--claude") => {
                    options.claude_config = Some(
                        dirs::config_dir()
                            .context("Cannot locate user configuration directory")?
                            .join("Claude/claude_desktop_config.json"),
                    );
                }
                Some("--claude-config") => {
                    options.claude_config = Some(PathBuf::from(
                        args.next().context("--claude-config requires a path")?,
                    ))
                }
                _ => bail!("Unknown option: {}", arg.to_string_lossy()),
            }
        }
        options.install_dir = std::path::absolute(options.install_dir)?;
        let metadata = read_metadata(&options.install_dir)?;
        if !aseprite_explicit && let Some(path) = metadata["aseprite_dir"].as_str() {
            options.aseprite_dir = PathBuf::from(path);
        }
        if options.claude_config.is_none() {
            options.claude_config = metadata["claude_config"].as_str().map(PathBuf::from);
        }
        options.aseprite_dir = std::path::absolute(options.aseprite_dir)?;
        Ok(options)
    }
}

pub async fn run() -> Result<bool> {
    let mut args = std::env::args_os().skip(1);
    let Some(command) = args.next() else {
        return Ok(false);
    };
    match command.to_str() {
        Some("serve") if args.next().is_none() => return Ok(false),
        Some("--version" | "-V") => println!("Rust Pixel Bridge {}", env!("CARGO_PKG_VERSION")),
        Some("--help" | "-h") => println!(
            "Rust Pixel Bridge\n\nUsage: asprite-mcp [serve | install | uninstall | doctor]\n\n  serve       Start the MCP server over stdio (default)\n  install     Install the executable, Aseprite extension and mcp.json\n  uninstall   Remove the extension and matching client registration\n  doctor      Check the extension and connection\n\nInstall / uninstall options:\n  --install-dir PATH     Application directory\n  --aseprite-dir PATH    Aseprite configuration directory\n  --claude               Configure Claude Desktop\n  --claude-config PATH   Use a specific Claude Desktop configuration\n\nEnvironment: RUST_PIXEL_QUEUE_DIR overrides the queue directory."
        ),
        Some("install") => install(&Options::parse(args)?)?,
        Some("uninstall") => uninstall(&Options::parse(args)?)?,
        Some("doctor") => {
            let options = Options::parse(args)?;
            let plugin = options
                .aseprite_dir
                .join("extensions/rust-pixel/package.json");
            println!("Rust Pixel Bridge {}", env!("CARGO_PKG_VERSION"));
            println!("Extension: {}", plugin.display());
            ensure!(
                plugin.is_file(),
                "Extension is not installed. Run asprite-mcp install first."
            );
            let queue_dir = installed_queue_dir(&options.install_dir)?;
            println!("Queue: {}", queue_dir.display());
            let queue = crate::queue::QueueManager::new(&queue_dir).await?;
            let status = queue.plugin_status().await?;
            queue.execute(crate::queue::Command::ExportContext).await?;
            println!("Aseprite: connected (extension {})", status.version);
        }
        _ => bail!(
            "Unknown command: {}. Use --help for usage.",
            command.to_string_lossy()
        ),
    }
    Ok(true)
}

fn binary_name() -> &'static str {
    if cfg!(windows) {
        "asprite-mcp.exe"
    } else {
        "asprite-mcp"
    }
}

fn registration(executable: &Path, queue_dir: &Path) -> Value {
    json!({ "command": executable, "args": [], "env": { "RUST_PIXEL_QUEUE_DIR": queue_dir } })
}

fn read_metadata(install_dir: &Path) -> Result<Value> {
    let path = install_dir.join("installation.json");
    if path.is_file() {
        serde_json::from_slice(&fs::read(path)?).context("Invalid installation metadata")
    } else {
        Ok(json!({}))
    }
}

fn installed_queue_dir(install_dir: &Path) -> Result<PathBuf> {
    if std::env::var_os("RUST_PIXEL_QUEUE_DIR").is_none()
        && let Some(path) = read_metadata(install_dir)?["queue_dir"].as_str()
    {
        return Ok(PathBuf::from(path));
    }
    crate::config::queue_dir()
}

fn install(options: &Options) -> Result<()> {
    let executable = options.install_dir.join(binary_name());
    let queue_dir = installed_queue_dir(&options.install_dir)?;
    let entry = registration(&executable, &queue_dir);
    let client_update = options
        .claude_config
        .as_deref()
        .map(|path| prepare_client(path, &entry))
        .transpose()?;
    let plugin_dir = options.aseprite_dir.join("extensions/rust-pixel");
    let agent_name = if cfg!(windows) {
        "rust-pixel-agent.exe"
    } else {
        "rust-pixel-agent"
    };
    let current = std::env::current_exe()?.canonicalize()?;
    let agent_source = current
        .parent()
        .context("Cannot locate executable directory")?
        .join(agent_name);
    ensure!(
        agent_source.is_file(),
        "Assistant executable not found. Build both binaries with cargo build --bins or use a Windows release package."
    );

    fs::create_dir_all(&options.install_dir)?;
    fs::create_dir_all(&plugin_dir)?;
    if !executable.exists() || executable.canonicalize()? != current {
        fs::copy(&current, &executable)
            .context("Cannot copy executable. Close the MCP client and try again.")?;
    }
    let agent_target = options.install_dir.join(agent_name);
    if !agent_target.exists() || agent_source.canonicalize()? != agent_target.canonicalize()? {
        fs::copy(&agent_source, &agent_target)
            .context("Cannot update the assistant. Close the Rust Pixel panel and try again.")?;
    }
    for (name, contents) in PLUGIN_FILES {
        fs::write(plugin_dir.join(name), contents)?;
    }
    write_json(
        &plugin_dir.join("bridge.json"),
        &json!({"queue_dir": queue_dir, "agent_path": agent_target}),
    )?;
    write_json(
        &options.install_dir.join("mcp.json"),
        &json!({"mcpServers": {"rust-pixel": entry}}),
    )?;
    write_json(
        &options.install_dir.join("installation.json"),
        &json!({
            "aseprite_dir": options.aseprite_dir,
            "claude_config": options.claude_config,
            "queue_dir": queue_dir,
        }),
    )?;
    for name in ["inbox", "outbox", "ack", "assets"] {
        fs::create_dir_all(queue_dir.join(name))?;
    }
    if let Some((path, document, existed)) = client_update {
        save_client(&path, &document, existed)?;
        println!("Claude Desktop configured. Restart the application.");
    }
    println!("Installed: {}", options.install_dir.display());
    println!("Extension: {}", plugin_dir.display());
    println!(
        "MCP configuration: {}",
        options.install_dir.join("mcp.json").display()
    );
    println!("Restart Aseprite. On first use, allow the extension to access its bridge files.");
    Ok(())
}

fn prepare_client(path: &Path, entry: &Value) -> Result<(PathBuf, Value, bool)> {
    let existed = path.exists();
    let mut document: Value = if existed {
        serde_json::from_slice(&fs::read(path)?).with_context(|| {
            format!(
                "Invalid JSON in {}. No client settings were changed.",
                path.display()
            )
        })?
    } else {
        json!({})
    };
    let root = document
        .as_object_mut()
        .context("Client configuration must be a JSON object")?;
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .context("mcpServers must be a JSON object")?;
    if let Some(existing) = servers.get("rust-pixel") {
        ensure!(
            existing == entry,
            "The client already has a different rust-pixel registration. Remove or rename it before installing."
        );
    }
    servers.insert("rust-pixel".into(), entry.clone());
    Ok((path.to_path_buf(), document, existed))
}

fn save_client(path: &Path, document: &Value, existed: bool) -> Result<()> {
    if existed {
        let backup = path.with_file_name(format!(
            "claude_desktop_config.{}.bak",
            uuid::Uuid::new_v4()
        ));
        fs::copy(path, &backup).context("Cannot back up client configuration")?;
    }
    write_json(path, document)
}

fn write_json(path: &Path, document: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let pending = path.with_file_name(format!(".{}.tmp", uuid::Uuid::new_v4()));
    fs::write(&pending, serde_json::to_vec_pretty(document)?)?;
    fs::rename(&pending, path).with_context(|| format!("Cannot write {}", path.display()))?;
    Ok(())
}

fn uninstall(options: &Options) -> Result<()> {
    let stored = read_metadata(&options.install_dir)?;
    let aseprite_dir = stored["aseprite_dir"]
        .as_str()
        .map(PathBuf::from)
        .unwrap_or_else(|| options.aseprite_dir.clone());
    let plugin_dir = aseprite_dir.join("extensions/rust-pixel");
    for name in [
        "init.lua",
        "bridge.lua",
        "panel.lua",
        "ui.lua",
        "panel-view.lua",
        "package.json",
        "bridge.json",
        "LICENSE",
    ] {
        let path = plugin_dir.join(name);
        if path.is_file() {
            fs::remove_file(path)?;
        }
    }
    if plugin_dir.is_dir() && fs::read_dir(&plugin_dir)?.next().is_none() {
        fs::remove_dir(&plugin_dir)?;
    }

    let client_path = options
        .claude_config
        .clone()
        .or_else(|| stored["claude_config"].as_str().map(PathBuf::from));
    if let Some(path) = client_path.filter(|path| path.is_file()) {
        let mut document: Value = serde_json::from_slice(&fs::read(&path)?)?;
        if let Some(servers) = document
            .get_mut("mcpServers")
            .and_then(Value::as_object_mut)
        {
            let executable = options.install_dir.join(binary_name());
            if servers
                .get("rust-pixel")
                .and_then(|entry| entry["command"].as_str())
                == executable.to_str()
            {
                servers.remove("rust-pixel");
                save_client(&path, &document, true)?;
            }
        }
    }
    for name in ["mcp.json", "installation.json"] {
        let path = options.install_dir.join(name);
        if path.is_file() {
            fs::remove_file(path)?;
        }
    }
    println!("Extension and client registration removed. Local assets were preserved.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merges_client_configuration_without_replacing_existing_settings() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("client.json");
        fs::write(
            &path,
            r#"{"theme":"dark","mcpServers":{"other":{"command":"other.exe"}}}"#,
        )
        .unwrap();
        let (_, doc, existed) = prepare_client(&path, &json!({"command":"bridge.exe"})).unwrap();
        assert!(existed);
        assert_eq!(doc["theme"], "dark");
        assert_eq!(doc["mcpServers"]["other"]["command"], "other.exe");
        assert_eq!(doc["mcpServers"]["rust-pixel"]["command"], "bridge.exe");
    }

    #[test]
    fn invalid_client_configuration_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("client.json");
        fs::write(&path, "invalid json").unwrap();
        assert!(prepare_client(&path, &json!({})).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "invalid json");
    }

    #[test]
    fn conflicting_registration_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("client.json");
        fs::write(
            &path,
            r#"{"mcpServers":{"rust-pixel":{"command":"custom.exe"}}}"#,
        )
        .unwrap();
        assert!(prepare_client(&path, &json!({"command":"bridge.exe"})).is_err());
    }
}
