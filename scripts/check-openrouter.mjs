import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, writeFile, readFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.argv[2] || path.join(root, 'target', 'release', 'rust-pixel-agent.exe');
const queue = path.join(root, 'target', `openrouter-catalog-${Date.now()}`);
const requests = path.join(queue, 'assistant', 'requests');
await mkdir(requests, { recursive: true });
const env = { ...process.env };
delete env.RUST_PIXEL_OPENROUTER_URL;
const worker = spawn(binary, ['--queue-dir', queue], { windowsHide: true, env });
const id = randomUUID();
const request = path.join(requests, `${id}.request.json`);
await writeFile(request + '.tmp', JSON.stringify({ id, action: 'models' }));
await rename(request + '.tmp', request);
try {
  const deadline = Date.now() + 30000;
  let response;
  while (Date.now() < deadline) {
    try {
      response = JSON.parse(await readFile(path.join(queue, 'assistant', 'responses', `${id}.json`), 'utf8'));
      if (response.done) break;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(response?.done && response.ok, response?.error || 'Catalog request timed out');
  assert(response.data.models.some(model => model.id.startsWith('anthropic/')));
  assert(response.data.models.some(model => model.id.startsWith('openai/')));
  assert(response.data.models.some(model => model.id.startsWith('google/')));
  console.log(`OpenRouter: ${response.data.models.length} models with tool support. No chat completion was requested.`);
} finally {
  if (worker.exitCode === null) worker.kill();
}
