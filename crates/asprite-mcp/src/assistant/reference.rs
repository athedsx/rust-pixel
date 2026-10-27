use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{fs, io::Cursor, path::Path};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct ReferenceImage {
    pub id: String,
    pub name: String,
}

pub(super) struct PreparedReference {
    pub image: ReferenceImage,
    pub data_url: String,
}

pub(super) fn prepare(
    root: &Path,
    reference: Option<&ReferenceImage>,
    vision: bool,
) -> Result<Option<PreparedReference>> {
    let Some(reference) = reference else {
        return Ok(None);
    };
    ensure!(
        vision,
        "Este modelo nao aceita imagens. Escolha um modelo com visao ou remova a referencia."
    );
    ensure!(
        uuid::Uuid::parse_str(&reference.id).is_ok()
            && reference.id.len() == 36
            && !reference.name.trim().is_empty()
            && reference.name.len() <= 1024
            && !reference.name.contains(char::is_control),
        "Referencia de imagem invalida. Anexe o arquivo novamente."
    );
    let directory = root.join("references").canonicalize()?;
    let path = directory
        .join(format!("{}.png", reference.id))
        .canonicalize()
        .context("A imagem de referencia nao esta mais disponivel. Anexe o arquivo novamente.")?;
    ensure!(
        path.parent() == Some(directory.as_path()),
        "Referencia fora da pasta de anexos."
    );
    let metadata = fs::metadata(&path)?;
    ensure!(
        metadata.is_file() && metadata.len() <= 8 * 1024 * 1024,
        "Referencia de imagem muito grande."
    );
    let bytes = fs::read(path)?;
    let mut reader = image::ImageReader::with_format(Cursor::new(bytes), image::ImageFormat::Png);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(1024);
    limits.max_image_height = Some(1024);
    limits.max_alloc = Some(32 * 1024 * 1024);
    reader.limits(limits);
    let image = reader
        .decode()
        .context("Referencia PNG invalida ou maior que 1024 pixels.")?;
    let mut png = Cursor::new(Vec::new());
    image.write_to(&mut png, image::ImageFormat::Png)?;
    let encoded =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, png.into_inner());
    Ok(Some(PreparedReference {
        image: reference.clone(),
        data_url: format!("data:image/png;base64,{encoded}"),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_local_reference_images() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("references");
        fs::create_dir(&directory).unwrap();
        let reference = ReferenceImage {
            id: uuid::Uuid::new_v4().to_string(),
            name: "referencia.png".into(),
        };
        let path = directory.join(format!("{}.png", reference.id));
        image::RgbaImage::new(2, 3).save(&path).unwrap();
        let prepared = prepare(root.path(), Some(&reference), true)
            .unwrap()
            .unwrap();
        assert_eq!(prepared.image, reference);
        assert!(prepared.data_url.starts_with("data:image/png;base64,"));
        assert!(prepare(root.path(), Some(&reference), false).is_err());
        let traversal = ReferenceImage {
            id: "../outside".into(),
            name: "outside.png".into(),
        };
        assert!(prepare(root.path(), Some(&traversal), true).is_err());
        fs::write(&path, b"not an image").unwrap();
        assert!(prepare(root.path(), Some(&reference), true).is_err());
        image::RgbaImage::new(1025, 1).save(&path).unwrap();
        assert!(prepare(root.path(), Some(&reference), true).is_err());
        fs::remove_file(path).unwrap();
        assert!(prepare(root.path(), Some(&reference), true).is_err());
        assert!(prepare(root.path(), None, false).unwrap().is_none());
    }
}
