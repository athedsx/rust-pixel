use crate::{
    queue::{Command, QueueManager},
    tools,
};
use anyhow::{Context, Result, ensure};
use pixel_core::{RecipeOp, validate_ops};
use rmcp::{
    ServerHandler,
    model::{
        CallToolRequestParam, CallToolResult, Content, ErrorData, Implementation, InitializeResult,
        ListToolsResult, PaginatedRequestParam, ServerCapabilities,
    },
    service::{RequestContext, RoleServer},
};
use tokio::fs;

#[derive(Clone)]
pub struct BridgeServer {
    pub(crate) queue: QueueManager,
    pub(crate) tools: tools::ToolSet,
}

impl BridgeServer {
    pub async fn new(queue_dir: &std::path::Path) -> Result<Self> {
        Ok(Self {
            queue: QueueManager::new(queue_dir).await?,
            tools: tools::ToolSet::new(),
        })
    }

    async fn handle_add_sprite(&self, args: tools::AddSpriteArgs) -> Result<CallToolResult> {
        let name = args.name.unwrap_or_else(|| "Sprite".into());
        ensure!(
            !name.trim().is_empty()
                && name.len() <= 128
                && !name
                    .chars()
                    .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c)),
            "name must contain 1 to 128 characters without path separators or reserved filename characters"
        );
        ensure!(
            args.png_base64.is_some() ^ args.recipe.is_some(),
            "Provide exactly one of png_base64 or recipe"
        );
        let (command, payload) = if let Some(encoded) = args.png_base64 {
            ensure!(encoded.len() <= 44_739_244, "PNG exceeds the 32 MiB limit");
            let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
                .context("Invalid base64 PNG")?;
            let reader = image::ImageReader::with_format(
                std::io::Cursor::new(&bytes),
                image::ImageFormat::Png,
            );
            let (width, height) = reader.into_dimensions().context("Invalid PNG")?;
            ensure!(
                (1..=4096).contains(&width) && (1..=4096).contains(&height),
                "PNG dimensions must be between 1 and 4096"
            );
            image::load_from_memory_with_format(&bytes, image::ImageFormat::Png)
                .context("Invalid PNG data")?;
            self.queue.plugin_status().await?;
            let path = self
                .queue
                .inbox_dir()
                .join(format!("{}.png", uuid::Uuid::new_v4()));
            fs::write(&path, bytes).await.context("Cannot write PNG")?;
            (
                Command::ImportSprite {
                    source_path: path.clone(),
                    sprite_name: name,
                },
                Some(path),
            )
        } else {
            let recipe = args.recipe.context("Missing recipe")?;
            recipe.validate()?;
            (
                Command::CreateSprite {
                    recipe,
                    sprite_name: name,
                },
                None,
            )
        };

        let result = self.queue.execute(command).await;
        if let Some(payload) = payload {
            let _ = fs::remove_file(payload).await;
        }
        let ack = result?;
        Ok(CallToolResult::success(vec![Content::json(ack.data)?]))
    }

    async fn handle_edit_sprite(
        &self,
        sprite_id: String,
        ops: Vec<RecipeOp>,
        frame: Option<u32>,
        layer: Option<String>,
    ) -> Result<CallToolResult> {
        validate_ops(&ops)?;
        let ack = self
            .queue
            .execute(Command::EditSprite {
                sprite_id,
                ops,
                frame,
                layer,
            })
            .await?;
        Ok(CallToolResult::success(vec![Content::json(ack.data)?]))
    }
}

impl ServerHandler for BridgeServer {
    fn get_info(&self) -> InitializeResult {
        InitializeResult {
            protocol_version: Default::default(),
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation {
                name: "asprite-mcp".into(),
                version: env!("CARGO_PKG_VERSION").into(),
            },
            instructions: Some("Rust Pixel Bridge: create and edit sprites in Aseprite. Frame indices start at zero. Use aseprite_context to obtain sprite IDs.".into()),
        }
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParam>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult {
            tools: self.tools.list(),
            next_cursor: None,
        })
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParam,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        self.invoke(
            request.name.as_ref(),
            serde_json::Value::Object(request.arguments.unwrap_or_default()),
        )
        .await
    }
}

impl BridgeServer {
    pub async fn invoke(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<CallToolResult, ErrorData> {
        let result: Result<CallToolResult> = match name {
            "aseprite_context" => self
                .queue
                .execute(Command::ExportContext)
                .await
                .and_then(|ack| Ok(CallToolResult::success(vec![Content::json(ack.data)?]))),
            "add_sprite" => {
                let args = serde_json::from_value(arguments)
                    .map_err(|e| ErrorData::invalid_params(e.to_string(), None))?;
                self.handle_add_sprite(args).await
            }
            "edit_sprite" => {
                let args: tools::EditSpriteArgs = serde_json::from_value(arguments)
                    .map_err(|e| ErrorData::invalid_params(e.to_string(), None))?;
                self.handle_edit_sprite(args.sprite_id, args.ops, args.frame, args.layer)
                    .await
            }
            "list_assets" => self
                .queue
                .list_assets()
                .await
                .and_then(|assets| Ok(CallToolResult::success(vec![Content::json(assets)?]))),
            "get_asset_preview" => {
                let args: tools::GetAssetPreviewArgs = serde_json::from_value(arguments)
                    .map_err(|e| ErrorData::invalid_params(e.to_string(), None))?;
                self.queue
                    .get_preview(&args.asset_id, args.max_size.unwrap_or(128))
                    .await
                    .map(|data| CallToolResult::success(vec![Content::image(data, "image/png")]))
            }
            _ => {
                return Err(ErrorData::method_not_found::<
                    rmcp::model::CallToolRequestMethod,
                >());
            }
        };
        Ok(result.unwrap_or_else(|error| {
            CallToolResult::error(vec![Content::text(format!("{error:#}"))])
        }))
    }
}
