use anyhow::Result;
use asprite_mcp::{bridge::BridgeServer, config, setup};
use rmcp::{ServiceExt, transport::stdio};
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    if setup::run().await? {
        return Ok(());
    }
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();
    let queue_dir = config::queue_dir()?;
    info!(queue_dir = %queue_dir.display(), "Starting Rust Pixel Bridge");
    let service = BridgeServer::new(&queue_dir).await?.serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
