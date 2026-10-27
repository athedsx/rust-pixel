#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[tokio::main]
async fn main() {
    if let Err(error) = asprite_mcp::assistant::run().await {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}
