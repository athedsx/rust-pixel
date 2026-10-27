# Contributing

Thanks for helping improve Rust Pixel Bridge. Small, focused changes are easier to review and test.

## Before opening an issue

Search existing issues, include the Rust Pixel and Aseprite versions, and describe the expected and actual behavior. Use a minimal reproduction that does not contain personal artwork, conversations or credentials.

Do not paste complete configuration files, authentication responses, API keys, access tokens or unreviewed logs into public issues. See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Development

Install Rust and Node.js. Windows packaging also requires Inno Setup; native integration tests require a separately installed Aseprite.

```sh
cargo build --bins --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
node --test scripts/test-publication.mjs
node scripts/check-publication.mjs
```

On Windows, test installation into isolated directories:

```powershell
node scripts/test-install.mjs target/debug/asprite-mcp.exe
.\scripts\test-aseprite.ps1 -AsepritePath 'C:\path\Aseprite.exe'
node scripts/test-mcp.mjs target/debug/asprite-mcp.exe 'C:\path\Aseprite.exe'
node scripts/test-assistant.mjs target/debug/rust-pixel-agent.exe 'C:\path\Aseprite.exe'
node scripts/test-codex.mjs target/debug/rust-pixel-agent.exe 'C:\path\Aseprite.exe'
```

The provider integration suites use local mocks; they do not perform paid inference or sign into an account. Tests generate their own images in ignored temporary directories. Do not add personal PNGs or sprites as fixtures.

`scripts/test-installer.ps1` installs and uninstalls the Setup package. Run it only in a disposable Windows profile with no existing Rust Pixel installation; it deliberately refuses to replace a real registered installation.

## Pull requests

- Explain the problem and the change; link an issue when applicable.
- Add a regression test for behavior changes.
- Preserve existing user settings, artwork and conversation history.
- Keep authentication in the official client or Windows Credential Manager.
- Do not commit generated binaries, images, runtime queues, logs or local paths.
- Run the checks above and review `git diff --cached` before committing. `node scripts/check-publication.mjs --staged` inspects the staged blobs, not just working files.

Commit using your own Git identity. No contributor agreement or co-author footer is required.

## Packaging and releases

Keep the Cargo workspace, plugin manifest and installer version aligned. `scripts/build-windows.ps1` packages only approved application files and remaps compiler paths to avoid embedding a developer's home directory. Artwork and local configuration must never be added to its allowlist.

Tagging a reviewed commit with `v<version>` runs the Windows packaging workflow. Release assets are built on GitHub-hosted runners, tested and published with SHA-256 checksums; do not upload a personal workspace or test directory.
