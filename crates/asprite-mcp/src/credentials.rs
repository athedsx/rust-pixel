#[cfg(windows)]
use anyhow::Context;
use anyhow::Result;

pub fn read() -> Result<Option<String>> {
    if let Ok(key) = std::env::var("OPENROUTER_API_KEY")
        && !key.trim().is_empty()
    {
        return Ok(Some(key));
    }
    read_saved()
}

#[cfg(windows)]
fn read_saved() -> Result<Option<String>> {
    use windows_sys::Win32::{Foundation::ERROR_NOT_FOUND, Security::Credentials::*};
    let target: Vec<u16> = "RustPixel/OpenRouter\0".encode_utf16().collect();
    let mut credential = std::ptr::null_mut();
    // CredRead allocates the credential; CredFree releases it after copying the blob.
    unsafe {
        if CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_NOT_FOUND as i32) {
                return Ok(None);
            }
            return Err(error).context("Cannot read the saved OpenRouter key");
        }
        let bytes = std::slice::from_raw_parts(
            (*credential).CredentialBlob,
            (*credential).CredentialBlobSize as usize,
        )
        .to_vec();
        CredFree(credential.cast());
        Ok(Some(
            String::from_utf8(bytes).context("Invalid saved credential")?,
        ))
    }
}

#[cfg(not(windows))]
fn read_saved() -> Result<Option<String>> {
    Ok(None)
}

#[cfg(windows)]
pub fn save(key: &str) -> Result<()> {
    use windows_sys::Win32::Security::Credentials::*;
    anyhow::ensure!(
        !key.is_empty() && key.len() <= 2560,
        "Invalid OpenRouter key length"
    );
    let mut target: Vec<u16> = "RustPixel/OpenRouter\0".encode_utf16().collect();
    let mut user: Vec<u16> = "OpenRouter\0".encode_utf16().collect();
    let mut bytes = key.as_bytes().to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_mut_ptr(),
        CredentialBlobSize: bytes.len() as u32,
        CredentialBlob: bytes.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: user.as_mut_ptr(),
        ..Default::default()
    };
    // Windows copies the blob into the current user's Credential Manager.
    let written = unsafe { CredWriteW(&credential, 0) };
    bytes.fill(0);
    anyhow::ensure!(
        written != 0,
        "Cannot save OpenRouter key: {}",
        std::io::Error::last_os_error()
    );
    Ok(())
}

#[cfg(not(windows))]
pub fn save(_key: &str) -> Result<()> {
    anyhow::bail!("Set OPENROUTER_API_KEY to configure credentials on this platform")
}
