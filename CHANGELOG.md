# Changelog

## 0.5.0

First public source release.

### Included

- Native Aseprite conversation panel with an anchored sidebar, formatted messages and multiline input.
- Codex account connection through the official local app-server protocol.
- OpenRouter connection through Windows Credential Manager and a searchable model catalog.
- Reference image attachments, thumbnails, removal controls and image-capability validation.
- Agent and Ask modes, cancellation, local history and sprite snapshots.
- MCP tools for inspecting, creating and editing sprites, palettes, layers and frames.
- Windows installer, portable ZIP and standalone extension packaging.
- Isolated native integration tests, publication checks and secret scanning.

### Known limitations

- The panel is an overlay; true docking is not available through the Aseprite extension API.
- The panel interface is currently in Portuguese.
- Windows packages are unsigned. Aseprite must be installed separately.
- Direct Claude Code and Antigravity account connections are not implemented; compatible external MCP clients can use the bridge.
