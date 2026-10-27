import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.argv[2] || path.join(root, 'target', 'debug', 'rust-pixel-agent.exe');
const queue = path.join(root, 'target', `codex-check-${Date.now()}`);
const assistant = path.join(queue, 'assistant');
await mkdir(path.join(assistant, 'requests'), { recursive: true });
const worker = spawn(binary, ['--queue-dir', queue], { windowsHide: true });
const workerExit = once(worker, 'exit');
let log = '';
worker.stderr.on('data', chunk => { log += chunk; });
async function waitFor(predicate, label) {
  const end = Date.now() + 60000;
  while (Date.now() < end) {
    try { const value = await predicate(); if (value) return value; } catch {}
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error(`Timeout: ${label}\n${log}`);
}
const json = async file => JSON.parse(await readFile(file, 'utf8'));
try {
  await waitFor(async () => (await json(path.join(assistant, 'status.json'))).ready, 'worker ready');
  const id = randomUUID();
  const request = path.join(assistant, 'requests', `${id}.request.json`);
  await writeFile(request + '.tmp', JSON.stringify({ id, action: 'models', provider: 'codex' }));
  await rename(request + '.tmp', request);
  const result = await waitFor(async () => {
    const value = await json(path.join(assistant, 'responses', `${id}.json`));
    return value.done && value;
  }, 'Codex model catalog');
  assert(result.ok, result.error);
  assert(result.data.models.length > 0);
  console.log(`Codex app-server: ${result.data.models.length} models returned. No inference or login was requested.`);
} finally {
  await writeFile(path.join(assistant, 'stop'), 'stop');
  await Promise.race([workerExit, new Promise(resolve => setTimeout(resolve, 3000))]);
  if (worker.exitCode === null) worker.kill();
}
