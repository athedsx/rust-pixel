# Rust Pixel Bridge

A native chat panel and MCP bridge for creating and editing pixel art in Aseprite.

[![CI](https://github.com/athedsx/rust-pixel/actions/workflows/ci.yml/badge.svg)](https://github.com/athedsx/rust-pixel/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Português](docs/README.pt-BR.md) · [Downloads](https://github.com/athedsx/rust-pixel/releases) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Features

- Native Aseprite controls, colors and pixel font.
- A right-anchored, resizable panel with formatted conversations and a multiline composer.
- Codex through the official local client, or OpenRouter with a searchable model catalog.
- Reference image attachments, with previews and support for sending the current sprite alongside them.
- Agent mode for drawing and editing; Ask mode for read-only discussion.
- Layers, frames, palettes, local snapshots and Aseprite's undo history.
- A stdio MCP server for compatible external clients.

This is early-release software. Save your work before testing a new version. The sidebar is an anchored overlay, not a docked editor column: Aseprite's extension API does not expose docking. The panel UI is currently in Portuguese.

## Windows installation

Requires Windows 10/11 x64 and Aseprite 1.3.15 or newer. Aseprite is installed separately and is not included in this project.

1. Download the Windows Setup from [Releases](https://github.com/athedsx/rust-pixel/releases). If no package is available yet, use the build instructions below.
2. Run the installer using the suggested folders. Portable Aseprite installations can select their own configuration folder.
3. Restart Aseprite and allow the extension's requested file and process access on first use.
4. Open **File > Scripts > Rust Pixel > Abrir painel**. Click the model button at the bottom, choose a provider and connect.

No Rust toolchain or open terminal is needed to use an installer build. Windows packages are currently unsigned; checksums accompany release assets.

### Providers

**Codex** uses the official local client and its existing account session. If necessary, connection opens the client's browser sign-in flow. The bridge does not copy login tokens into this repository. Install the [Codex CLI](https://developers.openai.com/codex/cli/) separately.

**OpenRouter** uses your API key, stored in Windows Credential Manager. Choose a tool-capable model from its catalog. Reference attachments require an image-capable model. Provider charges and account limits apply.

OpenRouter access to Anthropic or Google models does not connect a Claude Code or Antigravity subscription. External MCP clients can use the generated `mcp.json` independently of the panel.

### Working with the panel

**Enter** sends; **Shift+Enter** inserts a new line. **Referência** selects an image for the next request; the thumbnail's **X** removes it. **Usar sprite atual** attaches the current document separately. **Parar** interrupts a request, and **Desfazer** uses Aseprite's undo history.

PNG, JPEG, BMP, GIF and Aseprite references use the first frame. Input is limited to 20 MB and 16 megapixels. A copy is resized to at most 1024 pixels on its longest side; the source file is not modified.

## Privacy and local data

Conversation history, reference copies, snapshots and runtime queues stay in the user's local application-data folder. Selected images and editor context are sent to the selected provider when you submit a request. Treat these local files as private: conversation and image copies are not encrypted by this project.

The source repository and release packages do not include personal artwork, API keys, authentication files, local configuration, logs or build caches. Packaging uses an explicit file allowlist, and CI checks the publication boundary. See [SECURITY.md](SECURITY.md) for details and responsible reporting.

## Build and test

Use a stable Rust toolchain compatible with the workspace's declared minimum version. Node.js is needed for integration and publication checks.

```sh
cargo build --bins --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
node --test scripts/test-publication.mjs
node scripts/check-publication.mjs
```

On Windows, `build.bat` builds both executables, the extension, a ZIP and an Inno Setup installer in `dist/`. The build script uses an installed Inno Setup compiler or can download its pinned, signature-checked installer:

```powershell
.\scripts\build-windows.ps1 -BootstrapInno
```

The portable ZIP includes `install.bat` and `uninstall.bat`. Application data is retained on uninstall. For native Aseprite tests, provider mocks and installation checks, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

| Directory | Purpose |
| --- | --- |
| `aseprite-plugin/` | Native Lua extension and panel |
| `crates/asprite-mcp/` | MCP server, provider integrations and installation |
| `crates/pixel-core/` | Pixel recipes and rendering primitives |
| `scripts/`, `tests/` | Packaging, privacy checks and isolated integration tests |
| `installer/` | Windows Setup definition |

## Contributing

Bug reports and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting logs or sample files. Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). Aseprite and the supported providers are separate products; this project is not affiliated with or endorsed by their developers.
