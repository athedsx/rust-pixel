use anyhow::{Context, Result, bail, ensure};
use pixel_core::{Recipe, RecipeOp};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::{fs, time};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    ImportSprite {
        source_path: PathBuf,
        sprite_name: String,
    },
    CreateSprite {
        recipe: Recipe,
        sprite_name: String,
    },
    EditSprite {
        sprite_id: String,
        ops: Vec<RecipeOp>,
        frame: Option<u32>,
        layer: Option<String>,
    },
    ExportContext,
}

#[derive(Debug, Deserialize)]
pub struct Ack {
    pub command_id: String,
    pub success: bool,
    pub message: String,
    pub data: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct PluginStatus {
    pub updated_at: u64,
    pub enabled: bool,
    pub version: String,
}

#[derive(Clone)]
pub struct QueueManager {
    queue_dir: PathBuf,
    inbox_dir: PathBuf,
    ack_dir: PathBuf,
    assets_dir: PathBuf,
}

impl QueueManager {
    pub async fn new(queue_dir: &Path) -> Result<Self> {
        for name in ["inbox", "outbox", "ack", "assets"] {
            fs::create_dir_all(queue_dir.join(name))
                .await
                .with_context(|| format!("Cannot create queue directory: {name}"))?;
        }
        Ok(Self {
            queue_dir: queue_dir.to_path_buf(),
            inbox_dir: queue_dir.join("inbox"),
            ack_dir: queue_dir.join("ack"),
            assets_dir: queue_dir.join("assets"),
        })
    }

    pub fn inbox_dir(&self) -> &Path {
        &self.inbox_dir
    }

    pub async fn plugin_status(&self) -> Result<PluginStatus> {
        let data = fs::read(self.queue_dir.join("outbox/status.json"))
            .await
            .context("Aseprite is offline. Open Aseprite with the Rust Pixel extension enabled.")?;
        let status: PluginStatus = serde_json::from_slice(&data)?;
        ensure!(
            status.enabled && now()?.saturating_sub(status.updated_at) <= 5,
            "Aseprite is offline. Open Aseprite or enable File > Scripts > Rust Pixel > Enable bridge."
        );
        ensure!(
            status.version == env!("CARGO_PKG_VERSION"),
            "Extension version mismatch. Reinstall Rust Pixel Bridge and restart Aseprite."
        );
        Ok(status)
    }

    pub async fn execute(&self, command: Command) -> Result<Ack> {
        self.plugin_status().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let path = self
            .inbox_dir
            .join(format!("{:020}-{id}.cmd.json", now_millis()?));
        let pending = path.with_extension("tmp");
        let ack_path = self.ack_dir.join(format!("{id}.json"));
        let wrapper = serde_json::json!({
            "id": id,
            "expires_at": now()? + COMMAND_TIMEOUT.as_secs(),
            "command": command,
        });
        fs::write(&pending, serde_json::to_vec(&wrapper)?).await?;
        fs::rename(&pending, &path)
            .await
            .context("Cannot publish command")?;

        let result = time::timeout(COMMAND_TIMEOUT, async {
            loop {
                match fs::read(&ack_path).await {
                    Ok(data) => {
                        let ack: Ack = serde_json::from_slice(&data)?;
                        ensure!(ack.command_id == id, "Unexpected command acknowledgement");
                        ensure!(ack.success, "{}", ack.message);
                        return Ok(ack);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
                time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await;

        let _ = fs::remove_file(&path).await;
        let _ = fs::remove_file(&ack_path).await;
        match result {
            Ok(result) => result,
            Err(_) => bail!(
                "Aseprite did not respond within 15 seconds. Check the extension permissions and try again."
            ),
        }
    }

    pub async fn list_assets(&self) -> Result<Vec<crate::tools::AssetInfo>> {
        let mut assets = Vec::new();
        let mut entries = fs::read_dir(&self.assets_dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) == Some("json") {
                let data = fs::read(&path).await?;
                if let Ok(asset) = serde_json::from_slice(&data) {
                    assets.push(asset);
                }
            }
        }
        assets.sort_by(|a: &crate::tools::AssetInfo, b| a.name.cmp(&b.name));
        Ok(assets)
    }

    pub async fn get_preview(&self, asset_id: &str, max_size: u32) -> Result<String> {
        ensure!(
            !asset_id.is_empty()
                && asset_id.len() <= 80
                && asset_id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_'),
            "Invalid asset_id"
        );
        ensure!(
            (1..=1024).contains(&max_size),
            "max_size must be between 1 and 1024"
        );
        let original = self.assets_dir.join(format!("{asset_id}.png"));
        let image = image::open(&original).context("Asset preview not found")?;
        let image = image.resize(
            max_size.min(image.width()),
            max_size.min(image.height()),
            image::imageops::FilterType::Nearest,
        );
        let mut png = std::io::Cursor::new(Vec::new());
        image.write_to(&mut png, image::ImageFormat::Png)?;
        Ok(base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            png.into_inner(),
        ))
    }
}

fn now() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

fn now_millis() -> Result<u128> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn offline_bridge_does_not_queue_commands() {
        let temp = tempfile::tempdir().unwrap();
        let queue = QueueManager::new(temp.path()).await.unwrap();
        assert!(queue.execute(Command::ExportContext).await.is_err());
        assert!(
            std::fs::read_dir(queue.inbox_dir())
                .unwrap()
                .next()
                .is_none()
        );
    }

    #[tokio::test]
    async fn commands_wait_for_acknowledgement() {
        let temp = tempfile::tempdir().unwrap();
        let queue = QueueManager::new(temp.path()).await.unwrap();
        fs::write(
            temp.path().join("outbox/status.json"),
            serde_json::to_vec(&serde_json::json!({
                "updated_at": now().unwrap(), "enabled": true, "version": env!("CARGO_PKG_VERSION"),
            }))
            .unwrap(),
        )
        .await
        .unwrap();
        let worker = queue.clone();
        let task = tokio::spawn(async move { worker.execute(Command::ExportContext).await });
        let command_path = loop {
            let mut entries = fs::read_dir(queue.inbox_dir()).await.unwrap();
            if let Some(entry) = entries.next_entry().await.unwrap()
                && entry.path().extension().is_some_and(|ext| ext == "json")
            {
                break entry.path();
            }
            time::sleep(Duration::from_millis(10)).await;
        };
        let command: serde_json::Value =
            serde_json::from_slice(&fs::read(command_path).await.unwrap()).unwrap();
        let id = command["id"].as_str().unwrap();
        fs::write(
            queue.ack_dir.join(format!("{id}.json")),
            serde_json::to_vec(&serde_json::json!({
                "command_id": id, "success": true, "message": "ok", "data": {"sprites": []},
            }))
            .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(
            task.await.unwrap().unwrap().data.unwrap()["sprites"],
            serde_json::json!([])
        );
    }

    #[tokio::test]
    async fn preview_rejects_paths_and_invalid_sizes() {
        let temp = tempfile::tempdir().unwrap();
        let queue = QueueManager::new(temp.path()).await.unwrap();
        assert!(queue.get_preview("../file", 128).await.is_err());
        assert!(queue.get_preview("asset", 0).await.is_err());
    }
}
