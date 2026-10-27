import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, readFile, readdir, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.argv[2] || path.join(root, 'target', 'release', 'asprite-mcp.exe');
const testPath = path.join(root, 'target', `install-test-${Date.now()}`, 'com espaço');
const installDir = path.join(testPath, 'Programs', 'Rust Pixel Bridge');
const asepriteDir = path.join(testPath, 'Aseprite');
const clientPath = path.join(testPath, 'Claude', 'claude_desktop_config.json');
const queue = path.join(testPath, 'queue');
const env = { ...process.env, RUST_PIXEL_QUEUE_DIR: queue };
await mkdir(path.dirname(clientPath), { recursive: true });
await writeFile(clientPath, JSON.stringify({ theme: 'dark', mcpServers: { other: { command: 'other.exe' } } }));
const run = (executable, args, expected = 0, childEnv = env) => {
  const result = spawnSync(executable, args, { windowsHide: true, env: childEnv, encoding: 'utf8', timeout: 20000 });
  assert.equal(result.status, expected, `${result.stdout}\n${result.stderr}\n${result.error || ''}`);
  return result;
};
const json = async file => JSON.parse(await readFile(file, 'utf8'));
const installedBinary = path.join(installDir, 'asprite-mcp.exe');
run(binary, ['install', '--install-dir', installDir, '--aseprite-dir', asepriteDir, '--claude-config', clientPath]);
await access(installedBinary);
await access(path.join(installDir, 'rust-pixel-agent.exe'));
await access(path.join(asepriteDir, 'extensions', 'rust-pixel', 'init.lua'));
await access(path.join(asepriteDir, 'extensions', 'rust-pixel', 'panel.lua'));
for (const filename of ['init.lua', 'bridge.lua', 'panel.lua', 'panel-view.lua', 'ui.lua', 'package.json']) {
  assert.equal(
    await readFile(path.join(asepriteDir, 'extensions', 'rust-pixel', filename), 'utf8'),
    await readFile(path.join(root, 'aseprite-plugin', filename), 'utf8'),
    `Installed ${filename} must match the packaged source`,
  );
}
const bridgeConfig = await json(path.join(asepriteDir, 'extensions', 'rust-pixel', 'bridge.json'));
assert.equal(bridgeConfig.queue_dir, queue);
assert.equal(bridgeConfig.agent_path, path.join(installDir, 'rust-pixel-agent.exe'));
assert.equal((await json(path.join(installDir, 'mcp.json'))).mcpServers['rust-pixel'].command, installedBinary);
assert.equal((await json(clientPath)).theme, 'dark');
assert.equal((await json(clientPath)).mcpServers.other.command, 'other.exe');
assert.equal((await json(clientPath)).mcpServers['rust-pixel'].command, installedBinary);
assert((await readdir(path.dirname(clientPath))).some(name => name.endsWith('.bak')));

run(installedBinary, ['install']);
const metadata = await json(path.join(installDir, 'installation.json'));
assert.equal(metadata.aseprite_dir, asepriteDir);
assert.equal(metadata.claude_config, clientPath);
assert.equal(metadata.queue_dir, queue);
await writeFile(path.join(queue, 'assets', 'keep.txt'), 'asset');
await writeFile(path.join(asepriteDir, 'extensions', 'rust-pixel', 'keep.txt'), 'custom');
run(installedBinary, ['uninstall', '--install-dir', installDir]);
assert.equal((await json(clientPath)).mcpServers['rust-pixel'], undefined);
assert.equal((await json(clientPath)).mcpServers.other.command, 'other.exe');
assert.equal(await readFile(path.join(queue, 'assets', 'keep.txt'), 'utf8'), 'asset');
assert.equal(await readFile(path.join(asepriteDir, 'extensions', 'rust-pixel', 'keep.txt'), 'utf8'), 'custom');
await assert.rejects(access(path.join(asepriteDir, 'extensions', 'rust-pixel', 'init.lua')));

const invalidPath = path.join(testPath, 'invalid.json');
await writeFile(invalidPath, 'invalid json');
run(binary, ['install', '--install-dir', path.join(testPath, 'invalid-install'), '--aseprite-dir', asepriteDir, '--claude-config', invalidPath], 1);
assert.equal(await readFile(invalidPath, 'utf8'), 'invalid json');
await assert.rejects(access(path.join(testPath, 'invalid-install')));
console.log('Install integration passed: paths with spaces and accents, client merge, backups, reinstall, uninstall and asset preservation.');
console.log(`Results: ${testPath}`);
