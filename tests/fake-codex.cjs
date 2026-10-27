const assert = require('node:assert/strict');
const readline = require('node:readline');
const fs = require('node:fs');
const path = require('node:path');
const log = path.join(process.cwd(), 'protocol.jsonl');
const threads = new Map();
const calls = new Map();
let sequence = 0;
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const reply = (id, result) => send({ id, result });
const event = (method, params) => send({ method, params });
function tool(turn, name, args, next) {
  const id = `tool-${++sequence}`;
  calls.set(id, next);
  send({ id, method: 'item/tool/call', params: {
    threadId: turn.thread, turnId: turn.id, callId: id, tool: name, arguments: args,
  } });
}
function finish(turn, text) {
  const params = { threadId: turn.thread, turnId: turn.id, itemId: `message-${turn.id}` };
  event('item/agentMessage/delta', { ...params, delta: text.slice(0, 8) });
  event('item/agentMessage/delta', { ...params, delta: text.slice(8) });
  event('item/completed', { threadId: turn.thread, turnId: turn.id, item: {
    id: params.itemId, type: 'agentMessage', text,
  } });
  event('turn/completed', { threadId: turn.thread, turn: { id: turn.id, status: 'completed' } });
}
const lines = readline.createInterface({ input: process.stdin });
lines.on('line', line => {
  try {
    const message = JSON.parse(line);
    fs.appendFileSync(log, line + '\n');
    const { id, method, params = {} } = message;
    if (!method) {
      const next = calls.get(id);
      assert(next, `Unknown tool response ${id}`);
      calls.delete(id);
      next(message);
      return;
    }
    switch (method) {
      case 'initialize':
        assert(params.capabilities.experimentalApi);
        assert.equal(params.clientInfo.name, 'rust_pixel');
        assert(process.argv.includes('features.shell_tool=false'));
        assert(process.argv.includes('mcp_servers={}'));
        reply(id, { userAgent: 'test-codex' });
        break;
      case 'initialized': break;
      case 'account/read':
        reply(id, { account: { type: 'chatgpt', planType: 'test' }, requiresOpenaiAuth: true });
        break;
      case 'model/list':
        reply(id, { data: params.cursor ? [{ model: 'test-codex-text', displayName: 'Test Codex Text', isDefault: false, inputModalities: ['text'] }]
          : [{ model: 'test-codex', displayName: 'Test Codex', isDefault: true, inputModalities: ['text', 'image'] }],
          nextCursor: params.cursor ? null : 'page-2' });
        break;
      case 'thread/start': {
        assert.equal(params.sandbox, 'read-only');
        assert.equal(params.approvalPolicy, 'never');
        assert.deepEqual(params.environments, []);
        assert(params.dynamicTools.some(t => t.name === 'aseprite_context'));
        const thread = `thread-${++sequence}`;
        threads.set(thread, params);
        reply(id, { thread: { id: thread } });
        break;
      }
      case 'thread/resume':
        assert(threads.has(params.threadId));
        reply(id, { thread: { id: params.threadId } });
        break;
      case 'turn/start': {
        assert.deepEqual(params.environments, []);
        const turn = { id: `turn-${++sequence}`, thread: params.threadId };
        const requestText = params.input.find(i => i.type === 'text').text;
        const thread = threads.get(turn.thread);
        if (requestText.includes('cancel-start-test')) {
          setTimeout(() => reply(id, { turn: { id: turn.id, status: 'inProgress' } }), 250);
          break;
        }
        reply(id, { turn: { id: turn.id, status: 'inProgress' } });
        if (requestText.includes('cancel-test')) break;
        if (requestText.includes('ask-test')) {
          assert(!thread.dynamicTools.some(t => ['add_sprite', 'edit_sprite'].includes(t.name)));
          tool(turn, 'edit_sprite', {}, response => {
            assert.equal(response.result.success, false);
            finish(turn, 'Explicacao sem alterar o sprite.');
          });
          break;
        }
        if (requestText.includes('reference-test')) {
          const images = params.input.filter(i => i.type === 'image');
          assert.equal(images.length, 2, 'Reference and editor preview must remain separate');
          assert(params.input.some(i => i.type === 'text' && i.text.includes('Reference image (visual guidance')));
          for (const image of images) {
            assert(image.url.startsWith('data:image/png;base64,'));
            const png = Buffer.from(image.url.split(',')[1], 'base64');
            assert.equal(png.subarray(1, 4).toString(), 'PNG');
            assert.equal(png.readUInt32BE(16), 8);
          }
          finish(turn, 'Referencia visual recebida junto com o sprite atual.');
          break;
        }
        if (requestText.includes('continue-test')) {
          assert(params.input.some(i => i.type === 'image' && i.url.startsWith('data:image/png;base64,')));
          tool(turn, 'aseprite_context', {}, response => {
            assert(response.result.success);
            finish(turn, 'Contexto consultado com a previa do sprite.');
          });
          break;
        }
        const recipe = { width: 8, height: 8, frames: 2, layers: ['base', 'details'], ops: [
          { op: 'rect', x: 0, y: 0, width: 8, height: 8, color: { r: 255, g: 0, b: 0 } },
          { op: 'put_pixel', x: 1, y: 1, frame: 1, color: { r: 0, g: 255, b: 0 } },
          { op: 'put_pixel', x: 2, y: 2, layer: 'details', color: { r: 0, g: 0, b: 255, a: 128 } },
        ] };
        tool(turn, 'add_sprite', { name: 'Codex test', recipe }, response => {
          assert(response.result.success);
          const sprite = JSON.parse(response.result.contentItems[0].text);
          tool(turn, 'edit_sprite', { sprite_id: sprite.id, layer: 'base', frame: 0,
            ops: [{ op: 'put_pixel', x: 3, y: 3, color: { r: 0, g: 255, b: 0 } }] }, edited => {
            assert(edited.result.success);
            tool(turn, 'get_asset_preview', { asset_id: sprite.id }, preview => {
              assert(preview.result.success);
              assert(preview.result.contentItems.some(c => c.type === 'inputImage' && c.imageUrl.startsWith('data:image/png;base64,')));
              const deniedId = `unrelated-${++sequence}`;
              calls.set(deniedId, denied => {
                assert.equal(denied.error.code, -32601);
                finish(turn, 'Sprite criado e editado pelo Codex no Aseprite.');
              });
              send({ id: deniedId, method: 'item/commandExecution/requestApproval', params: { threadId: turn.thread, turnId: turn.id } });
            });
          });
        });
        break;
      }
      case 'turn/interrupt':
        reply(id, {});
        event('turn/completed', { threadId: params.threadId, turn: { id: params.turnId, status: 'interrupted' } });
        break;
      default: throw new Error(`Unexpected method ${method}`);
    }
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
    process.exit();
  }
});
