import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.argv[2] || path.join(root, 'target', 'release', 'asprite-mcp.exe');
const aseprite = process.argv[3] || process.env.ASEPRITE_PATH;
assert(aseprite, 'Pass the Aseprite executable as the second argument or set ASEPRITE_PATH');
const testPath = path.join(root, 'target', `mcp-test-${Date.now()}`);
const queue = path.join(testPath, 'queue');
await mkdir(queue, { recursive: true });
const env = { ...process.env, RUST_PIXEL_QUEUE_DIR: queue };
const host = spawn(aseprite, [
  '--batch', '--script-param', `root=${root}`, '--script-param', `queue=${queue}`,
  '--script', path.join(root, 'tests', 'aseprite-host.lua'),
], { windowsHide: true, env });
const hostExit = once(host, 'exit');
let hostLog = '';
host.stdout.on('data', chunk => { hostLog += chunk; });
host.stderr.on('data', chunk => { hostLog += chunk; });
const server = spawn(binary, [], { windowsHide: true, env });
const serverExit = once(server, 'exit');
let serverLog = '';
server.stderr.on('data', chunk => { serverLog += chunk; });
const pending = new Map();
let nextId = 1;
let protocolError;
const lines = readline.createInterface({ input: server.stdout });
lines.on('line', line => {
  try {
    const message = JSON.parse(line);
    if (message.id !== undefined) {
      const request = pending.get(message.id);
      assert(request, `Unexpected response ID ${message.id}`);
      clearTimeout(request.timer);
      pending.delete(message.id);
      if (message.error) request.reject(new Error(JSON.stringify(message.error)));
      else request.resolve(message.result);
    }
  } catch (error) {
    protocolError = error;
    for (const request of pending.values()) request.reject(error);
  }
});

function request(method, params = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timeout: ${method}\n${serverLog}\n${hostLog}`)), 20000);
    pending.set(id, { resolve, reject, timer });
    server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

const call = (name, args = {}) => request('tools/call', { name, arguments: args });
const data = result => {
  assert(!result.isError, JSON.stringify(result));
  return JSON.parse(result.content[0].text);
};

try {
  const initialized = await request('initialize', {
    protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'rust-pixel-test', version: '1' },
  });
  assert(initialized.capabilities.tools);
  server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const list = await request('tools/list');
  assert.equal(list.tools.length, 5);
  for (const tool of list.tools) assert.equal(tool.inputSchema.type, 'object');
  assert(list.tools.find(tool => tool.name === 'add_sprite').inputSchema.definitions.Recipe);

  for (let attempt = 0; attempt < 100; attempt++) {
    try { await readFile(path.join(queue, 'outbox', 'status.json')); break; }
    catch { await new Promise(resolve => setTimeout(resolve, 50)); }
  }
  assert.deepEqual(data(await call('aseprite_context')).sprites, []);
  const info = data(await call('add_sprite', {
    name: 'MCP test', recipe: {
      width: 8, height: 8, frames: 2, layers: ['base', 'details'],
      ops: [
        { op: 'rect', x: 0, y: 0, width: 8, height: 8, color: { r: 255, g: 0, b: 0 } },
        { op: 'put_pixel', x: 1, y: 1, frame: 1, color: { r: 0, g: 255, b: 0 } },
        { op: 'put_pixel', x: 2, y: 2, layer: 'details', color: { r: 0, g: 0, b: 255, a: 128 } },
      ],
    },
  }));
  assert.equal(info.frames, 2);
  assert.equal(info.layers.length, 2);
  assert.equal(data(await call('aseprite_context')).sprites[0].id, info.id);
  data(await call('edit_sprite', {
    sprite_id: info.id, frame: 0, layer: 'base',
    ops: [{ op: 'put_pixel', x: 3, y: 3, color: { r: 0, g: 255, b: 0 } }],
  }));
  assert((await call('edit_sprite', {
    sprite_id: info.id, frame: 99, layer: 'base', ops: [{ op: 'clear' }],
  })).isError, 'Invalid edit should report a tool error');
  assert.equal(data(await call('list_assets'))[0].id, info.id);
  const preview = await call('get_asset_preview', { asset_id: info.id, max_size: 4 });
  assert(!preview.isError);
  assert.equal(preview.content[0].type, 'image');
  const png = Buffer.from(preview.content[0].data, 'base64');
  assert.equal(png.subarray(1, 4).toString(), 'PNG');
  assert.equal(png.readUInt32BE(16), 4);
  assert.equal(png.readUInt32BE(20), 4);
  assert((await call('get_asset_preview', { asset_id: '../outside' })).isError);
  assert((await call('add_sprite', { recipe: { width: 0, height: 8 } })).isError);

  await writeFile(path.join(queue, 'stop'), 'stop');
  await hostExit;
  const result = JSON.parse(await readFile(path.join(queue, 'host-result.json'), 'utf8'));
  assert(result.success, `${result.error}\n${hostLog}`);
  assert((await call('aseprite_context')).isError, 'Closed Aseprite should be reported as offline');
  assert(!protocolError, protocolError?.message);
  console.log('MCP integration passed: stdio, tool schemas, Aseprite commands, snapshots, previews and offline detection.');
  console.log(`Results: ${testPath}`);
} finally {
  server.stdin.end();
  await Promise.race([serverExit, new Promise(resolve => setTimeout(resolve, 2000))]);
  if (server.exitCode === null) server.kill();
  if (host.exitCode === null) host.kill();
  for (const request of pending.values()) clearTimeout(request.timer);
  await writeFile(path.join(testPath, 'server.log'), serverLog);
  await writeFile(path.join(testPath, 'aseprite.log'), hostLog);
}
