use pixel_core::{Recipe, RecipeOp};
use rmcp::model::{JsonObject, Tool};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc};

#[derive(Debug, Serialize, Deserialize)]
pub struct AssetInfo {
    pub id: String,
    pub name: String,
    pub asset_type: String,
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub tags: Vec<String>,
    pub path: PathBuf,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AddSpriteArgs {
    /// PNG file contents encoded as base64. Provide either this or recipe.
    pub png_base64: Option<String>,
    /// Drawing recipe with native layers and animation frames.
    pub recipe: Option<Recipe>,
    /// Display name for the new sprite.
    pub name: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditSpriteArgs {
    /// Sprite ID returned by aseprite_context.
    pub sprite_id: String,
    pub ops: Vec<RecipeOp>,
    /// Zero-based frame index. Defaults to the active frame.
    pub frame: Option<u32>,
    /// Layer name. Defaults to the active layer or the first image layer.
    pub layer: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GetAssetPreviewArgs {
    pub asset_id: String,
    /// Maximum width and height in pixels, from 1 to 1024. Defaults to 128.
    pub max_size: Option<u32>,
}

#[derive(JsonSchema)]
struct EmptyArgs {}

fn schema<T: JsonSchema>() -> Arc<JsonObject> {
    let value =
        serde_json::to_value(schemars::schema_for!(T)).expect("JSON schema is serializable");
    Arc::new(value.as_object().expect("JSON schema is an object").clone())
}

#[derive(Clone)]
pub struct ToolSet {
    tools: Vec<Tool>,
}

impl ToolSet {
    pub fn new() -> Self {
        Self {
            tools: vec![
                Tool::new(
                    "aseprite_context",
                    "Read open sprites, layers and palettes from Aseprite",
                    schema::<EmptyArgs>(),
                ),
                Tool::new(
                    "add_sprite",
                    "Create a sprite from a PNG or drawing recipe. Returns the sprite ID after import.",
                    schema::<AddSpriteArgs>(),
                ),
                Tool::new(
                    "edit_sprite",
                    "Apply drawing operations to an open sprite. Frame indices start at zero.",
                    schema::<EditSpriteArgs>(),
                ),
                Tool::new(
                    "list_assets",
                    "List snapshots exported to the local asset library",
                    schema::<EmptyArgs>(),
                ),
                Tool::new(
                    "get_asset_preview",
                    "Read an asset preview as a PNG image",
                    schema::<GetAssetPreviewArgs>(),
                ),
            ],
        }
    }

    pub fn list(&self) -> Vec<Tool> {
        self.tools.clone()
    }
}

impl Default for ToolSet {
    fn default() -> Self {
        Self::new()
    }
}
