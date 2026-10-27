import assert from 'node:assert/strict';
import { test } from 'node:test';
import { inspectFile, redactLabel } from './check-publication.mjs';

test('artwork is private regardless of extension case or location', () => {
  for (const name of ['sprite.png', 'SPRITE.PNG', 'examples/art.aseprite', 'nested/animation.ASE',
    'reference.jpg', 'reference.JPEG', 'animation.gif', 'palette.bmp', 'reference.webp']) {
    assert(inspectFile(name, Buffer.from('private image')).some(item => item.category === 'private or generated file'));
  }
});

test('credentials, configuration, diagnostics and binaries cannot be published', () => {
  for (const name of ['.env', '.env.production', '.env.local', 'nested/auth.json', 'bridge.json',
    'mcp.json', 'run.log', 'run.log.1', 'protocol.jsonl', 'binary.exe', 'key.pem',
    'target/result.json', '.tools/report.txt', '.codex/settings.toml', 'queue/request.json']) {
    assert(inspectFile(name, Buffer.from('private data')).length, name);
  }
});

test('source code, manifests, docs and placeholder examples remain publishable', () => {
  for (const name of ['README.md', 'Cargo.lock', '.github/workflows/ci.yml', 'aseprite-plugin/package.json',
    'crates/asprite-mcp/src/main.rs', 'tests/aseprite.lua', '.env.example']) {
    assert.deepEqual(inspectFile(name, Buffer.from('ordinary source text\n')), []);
  }
});

test('secrets are flagged without returning their value or surrounding text', () => {
  const samples = [
    ['sk-' + 'or-v1-' + 'a'.repeat(48), 'provider credential'],
    ['ghp_' + 'b'.repeat(36), 'GitHub credential'],
    ['AKIA' + 'A'.repeat(16), 'cloud credential'],
    ['-----BEGIN ' + 'PRIVATE KEY-----', 'private key'],
  ];
  for (const [value, category] of samples) {
    const findings = inspectFile('sample.txt', Buffer.from(`line one\n${value}\n`));
    assert(findings.some(item => item.category === category && item.line === 2));
    assert(!JSON.stringify(findings).includes(value));
    assert(!redactLabel(value).includes(value));
  }
});

test('personal absolute paths are flagged without exposing the matched value', () => {
  for (const location of [['C:', 'Users', 'ExamplePerson', 'project'].join('\\'), ['', 'home', 'example-person', 'project', ''].join('/'),
    ['D:', 'rust-pixel', 'target'].join('\\')]) {
    const findings = inspectFile('sample.txt', Buffer.from(location));
    assert(findings.length);
    assert(!JSON.stringify(findings).includes(location));
  }
});

test('unknown binary data is blocked even under a text extension', () => {
  assert(inspectFile('unexpected.txt', Buffer.from([1, 0, 3])).some(item => item.category === 'unexpected binary file'));
});
