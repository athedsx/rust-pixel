import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, readFile, writeFile, rename, copyFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.argv[2] || path.join(root, 'target', 'debug', 'rust-pixel-agent.exe');
const aseprite = process.argv[3] || process.env.ASEPRITE_PATH;
assert(aseprite, 'Pass the Aseprite executable or set ASEPRITE_PATH');
const testPath = path.join(root, 'target', `codex-test-${Date.now()}`);
const queue = path.join(testPath, 'queue');
const assistant = path.join(queue, 'assistant');
const codex = path.join(assistant, 'codex');
await mkdir(path.join(assistant, 'requests'), { recursive: true });
await mkdir(codex, { recursive: true });
await copyFile(path.join(root, 'tests', 'fake-codex.cjs'), path.join(codex, 'app-server'));
const host = spawn(aseprite, ['--batch', '--script-param', `root=${root}`, '--script-param', `queue=${queue}`,
  '--script', path.join(root, 'tests', 'aseprite-host.lua')], { windowsHide: true });
const hostExit = once(host, 'exit');
const worker = spawn(binary, ['--queue-dir', queue], { windowsHide: true });
const workerExit = once(worker, 'exit');
let log = '';
for (const child of [host, worker]) {
  child.stdout.on('data', chunk => { log += chunk; });
  child.stderr.on('data', chunk => { log += chunk; });
}
const json = async file => JSON.parse(await readFile(file, 'utf8'));
async function waitFor(predicate, label, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    try { const value = await predicate(); if (value) return value; } catch {}
    await new Promise(resolve => setTimeout(resolve, 30));
  }
  throw new Error(`Timeout: ${label}\n${log}`);
}
async function start(action, values = {}) {
  const id = randomUUID();
  const request = path.join(assistant, 'requests', `${id}.request.json`);
  await writeFile(request + '.tmp', JSON.stringify({ id, action, provider: 'codex', ...values }));
  await rename(request + '.tmp', request);
  return id;
}
const result = async id => waitFor(async () => {
  const response = await json(path.join(assistant, 'responses', `${id}.json`));
  return response.done && response;
}, id);
const protocol = async () => (await readFile(path.join(codex, 'protocol.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
try {
  await waitFor(async () => (await json(path.join(assistant, 'status.json'))).ready, 'worker ready');
  await waitFor(async () => (await json(path.join(queue, 'outbox', 'status.json'))).enabled, 'Aseprite ready');
  const configured = await result(await start('configure', { codex_path: process.execPath }));
  assert(configured.ok, configured.error);
  const models = await result(await start('models'));
  assert(models.ok, models.error);
  assert.equal(models.data.models.length, 2);
  assert(models.data.models.some(m => m.id === 'test-codex' && m.default));
  const connected = await result(await start('connect'));
  assert(connected.ok && connected.data.providers.codex.configured);
  assert(!(await protocol()).some(m => m.method === 'account/login/start'), 'Existing login must be reused');
  const thread = randomUUID();
  const chat = await result(await start('chat', { thread_id: thread, prompt: 'Crie um sprite.', model: 'test-codex', mode: 'agent' }));
  assert(chat.ok, chat.error);
  assert(chat.messages.at(-1).text.includes('Sprite criado e editado'));
  const assetFile = (await readdir(path.join(queue, 'assets'))).find(name => name.endsWith('.json'));
  const asset = await json(path.join(queue, 'assets', assetFile));
  assert.equal(asset.frames, 2);
  assert.equal(asset.layers.length, 2);
  const continued = await result(await start('chat', { thread_id: thread, prompt: 'continue-test', model: 'test-codex', attach_asset: asset.id }));
  assert(continued.ok, continued.error);
  assert((await protocol()).some(m => m.method === 'thread/resume'));
  const reference = { id: randomUUID(), name: 'Referencia visual.png' };
  await mkdir(path.join(assistant, 'references'), { recursive: true });
  await copyFile(path.join(queue, 'assets', `${asset.id}.png`), path.join(assistant, 'references', `${reference.id}.png`));
  const turnsBefore = (await protocol()).filter(m => m.method === 'turn/start').length;
  const rejected = await result(await start('chat', { thread_id: randomUUID(), prompt: 'reference-test', model: 'test-codex-text', reference_image: reference }));
  assert(!rejected.ok && rejected.error.includes('nao aceita imagens'));
  assert.equal((await protocol()).filter(m => m.method === 'turn/start').length, turnsBefore, 'Text-only references must be rejected before starting inference');
  const referenced = await result(await start('chat', { thread_id: thread, prompt: 'reference-test', model: 'test-codex', attach_asset: asset.id, reference_image: reference }));
  assert(referenced.ok, referenced.error);
  assert.deepEqual(referenced.messages.find(m => m.text === 'reference-test').reference_image, reference);
  const reloaded = await result(await start('load', { thread_id: thread }));
  assert.deepEqual(reloaded.messages, referenced.messages);
  const before = await readFile(path.join(queue, 'assets', `${asset.id}.png`));
  const asked = await result(await start('chat', { thread_id: thread, prompt: 'ask-test', model: 'test-codex', mode: 'ask' }));
  assert(asked.ok, asked.error);
  assert(asked.messages.at(-1).text.includes('sem alterar'));
  assert.deepEqual(await readFile(path.join(queue, 'assets', `${asset.id}.png`)), before);
  const cancel = await start('chat', { thread_id: randomUUID(), prompt: 'cancel-test', model: 'test-codex' });
  await waitFor(async () => (await protocol()).some(m => m.method === 'turn/start' && JSON.stringify(m.params).includes('cancel-test')), 'turn to cancel');
  await writeFile(path.join(assistant, 'requests', `${cancel}.cancel`), 'cancel');
  const cancelled = await result(cancel);
  assert(!cancelled.ok && cancelled.error.includes('interrompido'));
  await waitFor(async () => (await protocol()).some(m => m.method === 'turn/interrupt'), 'Codex interruption');
  const cancelStart = await start('chat', { thread_id: randomUUID(), prompt: 'cancel-start-test', model: 'test-codex' });
  await waitFor(async () => (await protocol()).some(m => m.method === 'turn/start' && JSON.stringify(m.params).includes('cancel-start-test')), 'starting turn');
  await writeFile(path.join(assistant, 'requests', `${cancelStart}.cancel`), 'cancel');
  assert(!(await result(cancelStart)).ok);
  await waitFor(async () => (await protocol()).filter(m => m.method === 'turn/interrupt').length === 2, 'interruption during turn start');
  const loaded = await result(await start('load', { thread_id: thread }));
  assert.deepEqual(loaded.messages, asked.messages);
  await writeFile(path.join(queue, 'stop'), 'stop');
  await hostExit;
  const hostResult = await json(path.join(queue, 'host-result.json'));
  assert(hostResult.success, `${hostResult.error}\n${log}`);
  console.log('Codex integration passed: official protocol, existing login, models, streaming, native tools, reference images, vision checks, history, read-only mode and interruption. No paid inference.');
  console.log(`Results: ${testPath}`);
} finally {
  await writeFile(path.join(assistant, 'stop'), 'stop');
  await Promise.race([workerExit, new Promise(resolve => setTimeout(resolve, 3000))]);
  if (worker.exitCode === null) worker.kill();
  host.kill();
  await writeFile(path.join(testPath, 'test.log'), log);
}
