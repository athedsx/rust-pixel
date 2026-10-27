//! Core pixel art types and rendering logic shared between plugin and daemon.

use anyhow::{Context, Result, ensure};
use image::{ImageBuffer, Rgba};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A color in RGBA8 format
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    #[serde(default = "opaque")]
    pub a: u8,
}

fn opaque() -> u8 {
    255
}

impl Color {
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    pub fn to_rgba(&self) -> Rgba<u8> {
        Rgba([self.r, self.g, self.b, self.a])
    }

    pub fn from_rgba(rgba: Rgba<u8>) -> Self {
        Self {
            r: rgba[0],
            g: rgba[1],
            b: rgba[2],
            a: rgba[3],
        }
    }

    /// Distance in RGB space (ignoring alpha)
    pub fn distance_rgb(&self, other: &Color) -> u32 {
        let dr = self.r as i32 - other.r as i32;
        let dg = self.g as i32 - other.g as i32;
        let db = self.b as i32 - other.b as i32;
        (dr * dr + dg * dg + db * db) as u32
    }
}

/// A palette is an ordered list of colors
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Palette {
    pub name: String,
    pub colors: Vec<Color>,
}

impl Palette {
    pub fn new(name: impl Into<String>, colors: Vec<Color>) -> Self {
        Self {
            name: name.into(),
            colors,
        }
    }

    pub fn default_aseprite() -> Self {
        // Basic 16-color palette similar to Aseprite default
        Self::new(
            "default",
            vec![
                Color::rgb(0, 0, 0),
                Color::rgb(255, 255, 255),
                Color::rgb(128, 128, 128),
                Color::rgb(192, 192, 192),
                Color::rgb(255, 0, 0),
                Color::rgb(0, 255, 0),
                Color::rgb(0, 0, 255),
                Color::rgb(255, 255, 0),
                Color::rgb(255, 0, 255),
                Color::rgb(0, 255, 255),
                Color::rgb(128, 0, 0),
                Color::rgb(0, 128, 0),
                Color::rgb(0, 0, 128),
                Color::rgb(128, 128, 0),
                Color::rgb(128, 0, 128),
                Color::rgb(0, 128, 128),
            ],
        )
    }

    /// Find closest color index in palette
    pub fn closest_index(&self, color: &Color) -> usize {
        self.colors
            .iter()
            .enumerate()
            .min_by_key(|(_, c)| c.distance_rgb(color))
            .map(|(i, _)| i)
            .unwrap_or(0)
    }

    /// Quantize an image to this palette
    pub fn quantize_image(
        &self,
        img: &ImageBuffer<Rgba<u8>, Vec<u8>>,
    ) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
        if self.colors.is_empty() {
            return img.clone();
        }
        let (w, h) = img.dimensions();
        let mut out = ImageBuffer::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let px = img.get_pixel(x, y);
                let c = Color::from_rgba(*px);
                let idx = self.closest_index(&c);
                out.put_pixel(x, y, self.colors[idx].to_rgba());
            }
        }
        out
    }
}

/// Recipe format for programmatic pixel art generation
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum RecipeOp {
    /// Set a single pixel
    PutPixel {
        x: u32,
        y: u32,
        color: Color,
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Fill rectangle
    Rect {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        color: Color,
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Draw line (Bresenham)
    Line {
        x0: u32,
        y0: u32,
        x1: u32,
        y1: u32,
        color: Color,
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Horizontal line (optimized)
    HLine {
        x: u32,
        y: u32,
        width: u32,
        color: Color,
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Vertical line (optimized)
    VLine {
        x: u32,
        y: u32,
        height: u32,
        color: Color,
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Flood fill from point
    FloodFill {
        x: u32,
        y: u32,
        color: Color,
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Set palette for subsequent ops
    SetPalette { palette: Palette },
    /// Dither region with two colors
    Dither {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        color_a: Color,
        color_b: Color,
        density: f32, // 0.0 - 1.0
        frame: Option<u32>,
        layer: Option<String>,
    },
    /// Clear frame/layer to transparent
    Clear {
        frame: Option<u32>,
        layer: Option<String>,
    },
}

/// A complete recipe for generating an image/animation
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Recipe {
    pub width: u32,
    pub height: u32,
    #[serde(default = "one_frame")]
    pub frames: u32,
    #[serde(default = "default_layers")]
    pub layers: Vec<String>,
    pub palette: Option<Palette>,
    #[serde(default)]
    pub ops: Vec<RecipeOp>,
}

fn one_frame() -> u32 {
    1
}

fn default_layers() -> Vec<String> {
    vec!["default".into()]
}

impl Recipe {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            frames: 1,
            layers: vec!["default".into()],
            palette: None,
            ops: Vec::new(),
        }
    }

    pub fn with_frames(mut self, frames: u32) -> Self {
        self.frames = frames;
        self
    }

    pub fn with_layers(mut self, layers: Vec<String>) -> Self {
        self.layers = layers;
        self
    }

    pub fn with_palette(mut self, palette: Palette) -> Self {
        self.palette = Some(palette);
        self
    }

    pub fn add_op(&mut self, op: RecipeOp) {
        self.ops.push(op);
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            (1..=4096).contains(&self.width) && (1..=4096).contains(&self.height),
            "Canvas dimensions must be between 1 and 4096"
        );
        ensure!(
            (1..=256).contains(&self.frames),
            "frames must be between 1 and 256"
        );
        ensure!(
            !self.layers.is_empty() && self.layers.len() <= 64,
            "A recipe requires between 1 and 64 layers"
        );
        let mut names = std::collections::HashSet::new();
        for layer in &self.layers {
            ensure!(
                !layer.trim().is_empty() && names.insert(layer),
                "Layer names must be nonempty and unique"
            );
        }
        ensure!(
            u64::from(self.width)
                * u64::from(self.height)
                * u64::from(self.frames)
                * self.layers.len() as u64
                <= 16_777_216,
            "Recipe exceeds the 16 million pixel budget"
        );
        if let Some(palette) = &self.palette {
            palette.validate()?;
        }
        validate_ops(&self.ops)?;
        for op in &self.ops {
            ensure!(
                op.frame().is_none_or(|frame| frame < self.frames),
                "Operation frame is outside the recipe"
            );
            ensure!(
                op.layer().is_none_or(|layer| self.layers.contains(&layer)),
                "Operation references an unknown layer"
            );
        }
        Ok(())
    }
}

impl Palette {
    fn validate(&self) -> Result<()> {
        ensure!(
            !self.colors.is_empty() && self.colors.len() <= 256,
            "A palette requires between 1 and 256 colors"
        );
        Ok(())
    }
}

pub fn validate_ops(ops: &[RecipeOp]) -> Result<()> {
    ensure!(ops.len() <= 100_000, "Too many drawing operations");
    for op in ops {
        let coordinates: Vec<u32> = match op {
            RecipeOp::PutPixel { x, y, .. } | RecipeOp::FloodFill { x, y, .. } => vec![*x, *y],
            RecipeOp::Rect {
                x,
                y,
                width,
                height,
                ..
            }
            | RecipeOp::Dither {
                x,
                y,
                width,
                height,
                ..
            } => vec![*x, *y, *width, *height],
            RecipeOp::Line { x0, y0, x1, y1, .. } => vec![*x0, *y0, *x1, *y1],
            RecipeOp::HLine { x, y, width, .. } => vec![*x, *y, *width],
            RecipeOp::VLine { x, y, height, .. } => vec![*x, *y, *height],
            RecipeOp::Clear { .. } | RecipeOp::SetPalette { .. } => Vec::new(),
        };
        ensure!(
            coordinates.iter().all(|value| *value <= 65_535),
            "Coordinates and lengths must not exceed 65535"
        );
        if let RecipeOp::Dither { density, .. } = op {
            ensure!(
                density.is_finite() && (0.0..=1.0).contains(density),
                "density must be between 0 and 1"
            );
        }
        if let RecipeOp::SetPalette { palette } = op {
            palette.validate()?;
        }
    }
    Ok(())
}

/// Rendered frame data
#[derive(Debug, Clone)]
pub struct RenderedFrame {
    pub index: u32,
    pub layers: HashMap<String, ImageBuffer<Rgba<u8>, Vec<u8>>>,
    pub layer_order: Vec<String>,
}

/// Render a recipe to frames
pub fn render_recipe(recipe: &Recipe) -> Result<Vec<RenderedFrame>> {
    recipe.validate()?;
    let palette = recipe
        .palette
        .clone()
        .unwrap_or_else(Palette::default_aseprite);
    let mut frames = Vec::new();

    for frame_idx in 0..recipe.frames {
        let mut layers = HashMap::new();

        // Initialize all layers
        for layer_name in &recipe.layers {
            layers.insert(
                layer_name.clone(),
                ImageBuffer::from_pixel(recipe.width, recipe.height, Rgba([0, 0, 0, 0])),
            );
        }

        // Apply operations
        for op in &recipe.ops {
            let target_frame = op.frame().unwrap_or(frame_idx);
            if target_frame != frame_idx {
                continue;
            }

            let layer_name = op.layer().unwrap_or_else(|| recipe.layers[0].clone());
            let layer = layers.get_mut(&layer_name).context("Layer not found")?;

            apply_op(layer, &palette, op);
        }

        frames.push(RenderedFrame {
            index: frame_idx,
            layers,
            layer_order: recipe.layers.clone(),
        });
    }

    Ok(frames)
}

impl RecipeOp {
    fn frame(&self) -> Option<u32> {
        match self {
            RecipeOp::PutPixel { frame, .. }
            | RecipeOp::Rect { frame, .. }
            | RecipeOp::Line { frame, .. }
            | RecipeOp::HLine { frame, .. }
            | RecipeOp::VLine { frame, .. }
            | RecipeOp::FloodFill { frame, .. }
            | RecipeOp::Dither { frame, .. }
            | RecipeOp::Clear { frame, .. } => *frame,
            RecipeOp::SetPalette { .. } => None,
        }
    }

    fn layer(&self) -> Option<String> {
        match self {
            RecipeOp::PutPixel { layer, .. }
            | RecipeOp::Rect { layer, .. }
            | RecipeOp::Line { layer, .. }
            | RecipeOp::HLine { layer, .. }
            | RecipeOp::VLine { layer, .. }
            | RecipeOp::FloodFill { layer, .. }
            | RecipeOp::Dither { layer, .. }
            | RecipeOp::Clear { layer, .. } => layer.clone(),
            RecipeOp::SetPalette { .. } => None,
        }
    }
}

fn apply_op(layer: &mut ImageBuffer<Rgba<u8>, Vec<u8>>, _palette: &Palette, op: &RecipeOp) {
    let (w, h) = layer.dimensions();

    match op {
        RecipeOp::PutPixel { x, y, color, .. } => {
            if *x < w && *y < h {
                layer.put_pixel(*x, *y, color.to_rgba());
            }
        }
        RecipeOp::Rect {
            x,
            y,
            width,
            height,
            color,
            ..
        } => {
            let x_end = x.saturating_add(*width).min(w);
            let y_end = y.saturating_add(*height).min(h);
            for yy in *y..y_end {
                for xx in *x..x_end {
                    layer.put_pixel(xx, yy, color.to_rgba());
                }
            }
        }
        RecipeOp::Line {
            x0,
            y0,
            x1,
            y1,
            color,
            ..
        } => {
            draw_line(layer, *x0, *y0, *x1, *y1, color);
        }
        RecipeOp::HLine {
            x, y, width, color, ..
        } => {
            let x_end = x.saturating_add(*width).min(w);
            if *y < h {
                for xx in *x..x_end {
                    layer.put_pixel(xx, *y, color.to_rgba());
                }
            }
        }
        RecipeOp::VLine {
            x,
            y,
            height,
            color,
            ..
        } => {
            let y_end = y.saturating_add(*height).min(h);
            if *x < w {
                for yy in *y..y_end {
                    layer.put_pixel(*x, yy, color.to_rgba());
                }
            }
        }
        RecipeOp::FloodFill { x, y, color, .. } => {
            flood_fill(layer, *x, *y, color.to_rgba());
        }
        RecipeOp::SetPalette { .. } => {
            // RGBA operations carry their colors explicitly.
        }
        RecipeOp::Dither {
            x,
            y,
            width,
            height,
            color_a,
            color_b,
            density,
            ..
        } => {
            let x_end = x.saturating_add(*width).min(w);
            let y_end = y.saturating_add(*height).min(h);
            let ca = color_a.to_rgba();
            let cb = color_b.to_rgba();
            let d = *density;

            for yy in *y..y_end {
                for xx in *x..x_end {
                    // Bayer dither pattern (simple 2x2)
                    let pattern = match (xx & 1, yy & 1) {
                        (0, 0) => 0.0,
                        (1, 0) => 0.5,
                        (0, 1) => 0.75,
                        (1, 1) => 0.25,
                        _ => 0.0,
                    };
                    let c = if pattern < d { ca } else { cb };
                    layer.put_pixel(xx, yy, c);
                }
            }
        }
        RecipeOp::Clear { .. } => {
            for px in layer.pixels_mut() {
                *px = Rgba([0, 0, 0, 0]);
            }
        }
    }
}

fn draw_line(
    img: &mut ImageBuffer<Rgba<u8>, Vec<u8>>,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    color: &Color,
) {
    let (w, h) = img.dimensions();
    let mut x0 = x0 as i32;
    let mut y0 = y0 as i32;
    let x1 = x1 as i32;
    let y1 = y1 as i32;
    let dx = (x1 - x0).abs();
    let dy = (y1 - y0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut err = dx - dy;
    let c = color.to_rgba();

    loop {
        if x0 >= 0 && x0 < w as i32 && y0 >= 0 && y0 < h as i32 {
            img.put_pixel(x0 as u32, y0 as u32, c);
        }
        if x0 == x1 && y0 == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 > -dy {
            err -= dy;
            x0 += sx;
        }
        if e2 < dx {
            err += dx;
            y0 += sy;
        }
    }
}

fn flood_fill(img: &mut ImageBuffer<Rgba<u8>, Vec<u8>>, x: u32, y: u32, new_color: Rgba<u8>) {
    let (w, h) = img.dimensions();
    if x >= w || y >= h {
        return;
    }

    let target = *img.get_pixel(x, y);
    if target == new_color {
        return;
    }

    let mut stack = vec![(x as i32, y as i32)];
    while let Some((cx, cy)) = stack.pop() {
        if cx < 0 || cx >= w as i32 || cy < 0 || cy >= h as i32 {
            continue;
        }
        let px = *img.get_pixel(cx as u32, cy as u32);
        if px != target {
            continue;
        }
        img.put_pixel(cx as u32, cy as u32, new_color);
        stack.push((cx + 1, cy));
        stack.push((cx - 1, cy));
        stack.push((cx, cy + 1));
        stack.push((cx, cy - 1));
    }
}

/// Save rendered frames as PNG files (one per frame, layers composited)
pub fn save_frames_as_pngs(
    frames: &[RenderedFrame],
    output_dir: &std::path::Path,
    base_name: &str,
) -> Result<Vec<std::path::PathBuf>> {
    std::fs::create_dir_all(output_dir).context("create output dir")?;
    let mut paths = Vec::new();

    for frame in frames {
        let mut composite = ImageBuffer::from_pixel(
            frame.layers.values().next().map(|l| l.width()).unwrap_or(0),
            frame
                .layers
                .values()
                .next()
                .map(|l| l.height())
                .unwrap_or(0),
            Rgba([0, 0, 0, 0]),
        );

        for name in &frame.layer_order {
            image::imageops::overlay(&mut composite, &frame.layers[name], 0, 0);
        }

        let path = output_dir.join(format!("{}_{:04}.png", base_name, frame.index));
        composite.save(&path).context("save png")?;
        paths.push(path);
    }

    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_recipe_basic() {
        let mut recipe = Recipe::new(16, 16);
        recipe.add_op(RecipeOp::Rect {
            x: 0,
            y: 0,
            width: 16,
            height: 16,
            color: Color::rgb(255, 0, 0),
            frame: None,
            layer: None,
        });
        recipe.add_op(RecipeOp::Rect {
            x: 4,
            y: 4,
            width: 8,
            height: 8,
            color: Color::rgb(0, 255, 0),
            frame: None,
            layer: None,
        });

        let frames = render_recipe(&recipe).unwrap();
        assert_eq!(frames.len(), 1);
        let frame = &frames[0];
        let layer = frame.layers.get("default").unwrap();
        assert_eq!(layer.get_pixel(0, 0), &Rgba([255, 0, 0, 255]));
        assert_eq!(layer.get_pixel(8, 8), &Rgba([0, 255, 0, 255]));
    }

    #[test]
    fn test_palette_quantize() {
        let palette = Palette::new("test", vec![Color::rgb(0, 0, 0), Color::rgb(255, 255, 255)]);
        let mut img = ImageBuffer::new(4, 4);
        for y in 0..4 {
            for x in 0..4 {
                img.put_pixel(x, y, Rgba([128, 128, 128, 255]));
            }
        }
        let quantized = palette.quantize_image(&img);
        // All should become either black or white
        for y in 0..4 {
            for x in 0..4 {
                let px = quantized.get_pixel(x, y);
                assert!(px[0] == 0 || px[0] == 255);
            }
        }
    }

    #[test]
    fn rejects_empty_and_oversized_recipes() {
        assert!(render_recipe(&Recipe::new(0, 16)).is_err());
        assert!(render_recipe(&Recipe::new(16, 16).with_frames(0)).is_err());
        assert!(render_recipe(&Recipe::new(4096, 4096).with_frames(256)).is_err());
    }

    #[test]
    fn png_preserves_layer_order_and_transparency() {
        let mut recipe = Recipe::new(1, 1).with_layers(vec!["z_bottom".into(), "a_top".into()]);
        recipe.ops.push(RecipeOp::PutPixel {
            x: 0,
            y: 0,
            color: Color::new(255, 0, 0, 128),
            frame: None,
            layer: None,
        });
        recipe.ops.push(RecipeOp::PutPixel {
            x: 0,
            y: 0,
            color: Color::new(0, 0, 255, 128),
            frame: None,
            layer: Some("a_top".into()),
        });
        let temp = tempfile::tempdir().unwrap();
        let frames = render_recipe(&recipe).unwrap();
        let paths = save_frames_as_pngs(&frames, temp.path(), "sprite").unwrap();
        let image = image::open(&paths[0]).unwrap().to_rgba8();
        let pixel = image.get_pixel(0, 0);
        assert!(pixel[2] > pixel[0]);
        assert!((190..=192).contains(&pixel[3]));
    }
}
