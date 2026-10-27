import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const privateDirectories = new Set([
  'target', 'dist', '.tools', '.codex', '.claude', '.vscode', '.idea',
  '.rust-pixel', 'node_modules', 'queue', 'references', 'conversations',
]);
const privateNames = new Set([
  'auth.json', 'credentials.json', 'tokens.json', 'secrets.json', 'bridge.json',
  'installation.json', 'mcp.json', 'claude_desktop_config.json', 'id_rsa', 'id_ed25519',
]);
const privateExtension = /\.(?:png|jpe?g|gif|bmp|webp|ase|aseprite|log|jsonl|tmp|bak|dmp|pdb|exe|dll|msi|zip|7z|pem|key|p12|pfx|aseprite-extension)$/i;
const rules = [
  ['provider credential', /\bsk-(?:or-v1-|proj-|svcacct-)?[A-Za-z0-9_-]{24,}\b/g],
  ['GitHub credential', /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b/g],
  ['cloud credential', /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g],
  ['private key', /-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----/g],
  ['literal bearer credential', /["']?authorization["']?\s*[:=]\s*["']Bearer\s+[A-Za-z0-9._-]{24,}/gi],
  ['personal Windows path', /\b[A-Za-z]:[\\/]Users[\\/][^\\/\s<>"'`]+/gi],
  ['local workspace path', /\b[A-Za-z]:[\\/]rust-pixel(?:[\\/]|\b)/gi],
  ['personal Unix path', /\/(?:home|Users)\/[A-Za-z0-9_.-]+\//g],
];

export function inspectFile(filename, bytes) {
  const normalized = filename.replaceAll('\\', '/');
  const parts = normalized.toLowerCase().split('/');
  const basename = parts.at(-1);
  const findings = [];
  const add = (category, line = 1) => findings.push({ file: normalized, line, category });
  if (parts.slice(0, -1).some(part => privateDirectories.has(part))
    || privateNames.has(basename) || privateExtension.test(basename)
    || basename === '.env' || (basename.startsWith('.env.') && basename !== '.env.example')
    || basename.endsWith('.local.json') || /\.log\./i.test(basename)) {
    add('private or generated file');
    return findings;
  }
  const content = Buffer.from(bytes).toString('utf8');
  if (content.includes('\0')) {
    add('unexpected binary file');
    return findings;
  }
  for (const [category, regex] of rules) {
    regex.lastIndex = 0;
    for (const match of content.matchAll(regex)) {
      add(category, content.slice(0, match.index).split('\n').length);
    }
  }
  return findings;
}

export function redactLabel(value) {
  for (const [, regex] of rules) {
    regex.lastIndex = 0;
    value = value.replace(regex, '[redacted]');
  }
  return value;
}

export function scanRepository({ staged = false } = {}) {
  const git = args => execFileSync('git', args, { cwd: root, windowsHide: true, maxBuffer: 32 * 1024 * 1024 });
  const args = staged ? ['ls-files', '--cached', '-z']
    : ['ls-files', '--cached', '--others', '--exclude-standard', '-z'];
  const files = [...new Set(git(args).toString('utf8').split('\0').filter(Boolean))];
  const findings = [];
  for (const file of files) {
    try {
      const contents = staged ? git(['show', `:${file}`]) : readFileSync(path.join(root, file));
      findings.push(...inspectFile(file, contents));
    } catch {
      findings.push({ file, line: 1, category: 'file could not be inspected' });
    }
  }
  return { files, findings };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { files, findings } = scanRepository({ staged: process.argv.includes('--staged') });
    for (const finding of findings) {
      console.error(`${redactLabel(finding.file)}:${finding.line}: ${finding.category}`);
    }
    if (findings.length) {
      console.error(`Publication blocked: ${findings.length} finding(s). Matched values are never printed.`);
      process.exitCode = 1;
    } else {
      console.log(`Publication check passed: ${files.length} source files; no artwork, runtime data, common credentials or personal paths detected.`);
    }
  } catch {
    console.error('Publication check failed. Run it from a Git checkout and inspect Git status. No file contents were printed.');
    process.exitCode = 1;
  }
}
