import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, readFile, writeFile, rename, readdir, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.argv[2] || path.join(root, 'target', 'debug', 'rust-pixel-agent.exe');
const aseprite = process.argv[3] || process.env.ASEPRITE_PATH;
assert(aseprite, 'Pass the Aseprite executable as the second argument or set ASEPRITE_PATH');
const testPath = path.join(root, 'target', `assistant-test-${Date.now()}`);
const queue = path.join(testPath, 'queue');
const assistantPath = path.join(queue, 'assistant');
await mkdir(path.join(assistantPath, 'requests'), { recursive: true });
const apiRequests = [];
let catalogRequests = 0;
let latestSprite;
const recipe = {
  width: 8, height: 8, frames: 2, layers: ['base', 'details'], ops: [
    { op: 'rect', x: 0, y: 0, width: 8, height: 8, color: { r: 255, g: 0, b: 0 } },
    { op: 'put_pixel', x: 1, y: 1, frame: 1, color: { r: 0, g: 255, b: 0 } },
    { op: 'put_pixel', x: 2, y: 2, layer: 'details', color: { r: 0, g: 0, b: 255, a: 128 } },
  ],
};
const api = createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  if (req.url === '/models') {
    catalogRequests++;
    res.end(JSON.stringify({ data: [
      { id: 'mock/vision', name: 'Test Vision', supported_parameters: ['tools'], architecture: { input_modalities: ['text', 'image'] } },
      { id: 'mock/text', name: 'Test Text', supported_parameters: ['tools'], architecture: { input_modalities: ['text'] } },
      { id: 'mock/no-tools', name: 'No Tools', supported_parameters: [] },
    ] }));
    return;
  }
  if (req.url === '/key') {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: { message: 'Invalid test key' } }));
    return;
  }
  assert.equal(req.url, '/chat/completions');
  assert.equal(req.headers.authorization, 'Bearer test-key');
  let raw = '';
  for await (const chunk of req) raw += chunk;
  const body = JSON.parse(raw);
  apiRequests.push(body);
  const userText = body.messages.filter(m => m.role === 'user').map(m => JSON.stringify(m.content)).join('\n');
  if (userText.includes('cancel-test')) {
    const timer = setTimeout(() => res.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: 'Delayed' } }] })), 10000);
    res.on('close', () => clearTimeout(timer));
    return;
  }
  if (userText.includes('ask-test')) {
    assert(!body.tools.some(t => ['add_sprite', 'edit_sprite'].includes(t.function.name)));
    res.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: 'Explicacao sem alterar o sprite.' } }] }));
    return;
  }
  if (userText.includes('reference-test')) {
    const content = body.messages.filter(m => m.role === 'user').at(-1).content;
    const images = content.filter(item => item.type === 'image_url');
    assert.equal(images.length, 2, 'Reference and current sprite must be sent as separate images');
    assert(content.some(item => item.type === 'text' && item.text.includes('Reference image (visual guidance')));
    for (const item of images) {
      const png = Buffer.from(item.image_url.url.split(',')[1], 'base64');
      assert.equal(png.subarray(1, 4).toString(), 'PNG');
      assert.equal(png.readUInt32BE(16), 8);
      assert.equal(png.readUInt32BE(20), 8);
    }
    res.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: 'Referencia visual recebida junto com o sprite atual.' } }] }));
    return;
  }
  const toolMessages = body.messages.filter(m => m.role === 'tool');
  let name, args;
  if (toolMessages.length === 0) { name = 'add_sprite'; args = { name: 'Assistant test', recipe }; }
  else if (toolMessages.length === 1) {
    const result = JSON.parse(toolMessages[0].content);
    assert.equal(result.isError, false);
    latestSprite = JSON.parse(result.content[0]);
    name = 'edit_sprite';
    args = { sprite_id: latestSprite.id, frame: 0, layer: 'base', ops: [{ op: 'put_pixel', x: 3, y: 3, color: { r: 0, g: 255, b: 0 } }] };
  } else if (toolMessages.length === 2) { name = 'get_asset_preview'; args = { asset_id: latestSprite.id }; }
  else {
    assert(body.messages.some(m => m.role === 'user' && Array.isArray(m.content) && m.content.some(c => c.type === 'image_url')));
    res.end(JSON.stringify({ model: 'mock/vision', usage: { total_tokens: 100 }, choices: [{ message: { role: 'assistant', content: 'Sprite criado e editado no Aseprite.' } }] }));
    return;
  }
  res.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: randomUUID(), type: 'function', function: { name, arguments: JSON.stringify(args) } }] } }] }));
});
api.listen(0, '127.0.0.1');
await once(api, 'listening');
const env = { ...process.env, RUST_PIXEL_QUEUE_DIR: queue, OPENROUTER_API_KEY: 'test-key', RUST_PIXEL_OPENROUTER_URL: `http://127.0.0.1:${api.address().port}` };
const host = spawn(aseprite, ['--batch', '--script-param', `root=${root}`, '--script-param', `queue=${queue}`, '--script', path.join(root, 'tests', 'aseprite-host.lua')], { windowsHide: true, env });
const hostExit = once(host, 'exit');
const worker = spawn(binary, ['--queue-dir', queue], { windowsHide: true, env });
let log = '';
for (const child of [host, worker]) {
  child.stdout.on('data', chunk => { log += chunk; });
  child.stderr.on('data', chunk => { log += chunk; });
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const json = async file => JSON.parse(await readFile(file, 'utf8'));
async function waitFor(predicate, label, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    try { const value = await predicate(); if (value) return value; } catch {}
    await sleep(30);
  }
  throw new Error(`Timeout: ${label}\n${log}`);
}
async function start(action, values = {}) {
  const id = randomUUID();
  const filename = path.join(assistantPath, 'requests', `${id}.request.json`);
  await writeFile(filename + '.tmp', JSON.stringify({ id, action, ...values }));
  await rename(filename + '.tmp', filename);
  return id;
}
async function result(id) {
  return waitFor(async () => { const response = await json(path.join(assistantPath, 'responses', `${id}.json`)); return response.done && response; }, id);
}
try {
  await waitFor(async () => (await json(path.join(assistantPath, 'status.json'))).ready, 'assistant ready');
  await waitFor(async () => (await json(path.join(queue, 'outbox', 'status.json'))).enabled, 'Aseprite ready');
  const models = await result(await start('models'));
  assert(models.ok);
  assert.equal(models.data.models.length, 3);
  assert(!models.data.models.some(m => m.id === 'mock/no-tools'));
  assert.equal(catalogRequests, 1);
  const secondWorker = spawn(binary, ['--queue-dir', queue], { windowsHide: true, env });
  const [secondExit] = await once(secondWorker, 'exit');
  assert.equal(secondExit, 0, 'A second worker should exit without taking over the queue');
  const configured = await result(await start('configure', { model: 'mock/vision' }));
  assert(configured.ok && configured.data.configured);
  const thread = randomUUID();
  const chat = await result(await start('chat', { thread_id: thread, prompt: 'Crie e refine um sprite de teste.', model: 'mock/vision', mode: 'agent' }));
  assert(chat.ok, chat.error);
  assert(chat.messages.some(m => m.role === 'tool' && m.text.includes('Criando sprite')));
  assert(chat.messages.some(m => m.role === 'assistant' && m.text.includes('Sprite criado')));
  assert.equal(apiRequests.length, 4);
  const loaded = await result(await start('load', { thread_id: thread }));
  assert.deepEqual(loaded.messages, chat.messages);
  const reference = { id: randomUUID(), name: 'Referencia do personagem.png' };
  await mkdir(path.join(assistantPath, 'references'), { recursive: true });
  await copyFile(path.join(queue, 'assets', `${latestSprite.id}.png`), path.join(assistantPath, 'references', `${reference.id}.png`));
  const rejected = await result(await start('chat', { thread_id: randomUUID(), prompt: 'reference-test', model: 'mock/text', reference_image: reference }));
  assert(!rejected.ok && rejected.error.includes('nao aceita imagens'));
  const missing = await result(await start('chat', { thread_id: randomUUID(), prompt: 'reference-test', model: 'mock/vision', reference_image: { ...reference, id: randomUUID() } }));
  assert(!missing.ok && missing.error.includes('Anexe o arquivo novamente'));
  const traversal = await result(await start('chat', { thread_id: randomUUID(), prompt: 'reference-test', model: 'mock/vision', reference_image: { ...reference, id: '../outside' } }));
  assert(!traversal.ok);
  assert.equal(apiRequests.length, 4, 'Invalid references must be rejected before making any inference request');
  const referenced = await result(await start('chat', { thread_id: thread, prompt: 'reference-test', model: 'mock/vision', mode: 'ask', attach_asset: latestSprite.id, reference_image: reference }));
  assert(referenced.ok, referenced.error);
  assert.deepEqual(referenced.messages.find(m => m.text === 'reference-test').reference_image, reference);
  const reloaded = await result(await start('load', { thread_id: thread }));
  assert.deepEqual(reloaded.messages, referenced.messages, 'Reference metadata must survive conversation reload');
  const asked = await result(await start('chat', { thread_id: thread, prompt: 'ask-test', model: 'mock/vision', mode: 'ask' }));
  assert(asked.ok);
  assert(asked.messages.at(-1).text.includes('sem alterar'));
  const cancelId = await start('chat', { thread_id: randomUUID(), prompt: 'cancel-test', model: 'mock/vision' });
  await waitFor(() => apiRequests.some(b => JSON.stringify(b).includes('cancel-test')), 'request to cancel');
  await writeFile(path.join(assistantPath, 'requests', `${cancelId}.cancel`), 'cancel');
  const cancelled = await result(cancelId);
  assert(!cancelled.ok && cancelled.error.includes('interrompido'));
  const invalid = await result(await start('configure', { api_key: 'invalid-test-key' }));
  assert(!invalid.ok && !JSON.stringify(invalid).includes('invalid-test-key'));
  assert(!(await readdir(path.join(assistantPath, 'requests'))).some(name => name.endsWith('.request.json')));
  await writeFile(path.join(queue, 'stop'), 'stop');
  await hostExit;
  const hostResult = await json(path.join(queue, 'host-result.json'));
  assert(hostResult.success, `${hostResult.error}\n${log}`);
  console.log('Assistant integration passed: model catalog, tool loop, native drawing, reference images, vision checks, saved conversation, ask mode, cancellation and key error handling. No paid inference.');
  console.log(`Results: ${testPath}`);
} finally {
  if (worker.exitCode === null) worker.kill();
  if (host.exitCode === null) host.kill();
  api.closeAllConnections();
  api.close();
  await writeFile(path.join(testPath, 'test.log'), log);
}
