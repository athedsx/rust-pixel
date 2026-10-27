# Security policy

## Reporting a vulnerability

Do not report credentials or exploitable vulnerabilities in a public issue. Use [GitHub private vulnerability reporting](https://github.com/athedsx/rust-pixel/security/advisories/new) when available. If private reporting is unavailable, open an issue asking for a private reporting channel without including sensitive details.

Include the affected version, impact and a minimal reproduction using dummy data. Remove tokens, account identifiers, personal paths, conversations and artwork from attachments.

Security fixes target the latest release and the default branch. This early-release project does not guarantee support for older versions or a fixed response time.

## Data and authentication

- OpenRouter keys are stored in Windows Credential Manager, not in repository files.
- Codex authentication remains with the official local client. Rust Pixel does not copy its token store.
- Conversations, image references, snapshots and queue files are stored locally in the user's application-data folder. These files are not encrypted by this project.
- Submitting a request sends its prompt, selected images and editor context to the selected provider. Review provider policies before submitting sensitive material.
- The native MCP bridge uses stdio and a local filesystem queue. Do not expose the queue through a public share or run untrusted commands against it.
- Aseprite permissions are granted by Aseprite itself. The installer does not bypass its security prompts.

## Publication safeguards

`.gitignore` excludes personal images and sprites, local configuration, credentials, runtime data, logs and generated packages. Ignoring a file does not remove it from existing Git history.

The publication check rejects prohibited files, common secret formats and personal absolute paths. CI also scans Git history with Gitleaks. These are safeguards, not proof that every possible secret can be detected; always review the staged diff and release manifest.

Release packages are built from an explicit allowlist. They do not contain user artwork, local configuration or diagnostic output. Windows installers are currently unsigned; verify the checksums published with a release.

If a live credential is ever committed, revoke or rotate it at its provider immediately. Removing a file or rewriting Git history alone does not invalidate the credential.
