'use strict';
// Inert compatibility fixture: no network, child process, account, mail or user-file APIs.
// The host copies this shipped file into a fresh private per-case directory.
const fs = require('node:fs');
const path = require('node:path');
const MAX_INPUT = 262144, MAX_LINE = 65536, MAX_OUTPUT = 16384, MAX_NOTES = 64;
const tools = ['allow', 'deny', 'stall'];
let fd, notes = 0, input = 0, output = 0, pending = Buffer.alloc(0), closed = false;
let initialized = false, listed = false;
const called = new Set();
try {
  const root = fs.realpathSync(__dirname);
  const info = fs.lstatSync(root);
  if (root !== __dirname || process.argv.length !== 2 || !info.isDirectory()
      || info.uid !== process.getuid() || (info.mode & 0o7777) !== 0o700
      || !/^case-(tools|cancel)$/.test(path.basename(root))
      || !/^compatibility-[0-9A-F-]{36}$/i.test(path.basename(path.dirname(root)))) process.exit(2);
  if (fs.readdirSync(root).filter(x => /^ledger-/.test(x)).length >= 4) process.exit(2);
  fd = fs.openSync(path.join(root, `ledger-${process.pid}.jsonl`),
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  fs.fchmodSync(fd, 0o600);
  const file = fs.fstatSync(fd);
  if (!file.isFile() || file.nlink !== 1 || file.uid !== process.getuid()) process.exit(2);
} catch { process.exit(2); }

function note(event) {
  if (++notes > MAX_NOTES) process.exit(2);
  // Closed metadata vocabulary only; never any request or response contents.
  const data = Buffer.from(JSON.stringify({ event, pid: process.pid, parentPID: process.ppid }) + '\n');
  try {
    let offset = 0;
    while (offset < data.length) {
      const count = fs.writeSync(fd, data, offset, data.length - offset);
      if (count <= 0) process.exit(2);
      offset += count;
    }
    fs.fsyncSync(fd);
  } catch { process.exit(2); }
}
function stop(event, code = 2) {
  if (closed) return;
  closed = true; note(event); fs.closeSync(fd); process.exit(code);
}
function send(value) {
  const data = Buffer.from(JSON.stringify(value) + '\n');
  if ((output += data.length) > MAX_OUTPUT) return stop('output_limit');
  process.stdout.write(data);
}
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function receive(line) {
  let m;
  try { m = JSON.parse(line.toString('utf8')); } catch { return stop('invalid_input'); }
  if (!object(m) || m.jsonrpc !== '2.0' || typeof m.method !== 'string') return stop('invalid_input');
  if (!Object.hasOwn(m, 'id')) return;
  if (!(typeof m.id === 'string' && Buffer.byteLength(m.id) <= 256)
      && !(typeof m.id === 'number' && Number.isSafeInteger(m.id))) return stop('invalid_input');
  const p = m.params ?? {};
  if (!object(p)) return stop('invalid_input');
  if (m.method === 'initialize') {
    if (typeof p.protocolVersion !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(p.protocolVersion)) return stop('invalid_input');
    initialized = true; note('initialized');
    return send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: p.protocolVersion,
      capabilities: { tools: {} }, serverInfo: { name: 'openbots-inert-compatibility', version: '1' } } });
  }
  if (m.method === 'ping') return send({ jsonrpc: '2.0', id: m.id, result: {} });
  if (m.method === 'tools/list') {
    if (!listed) { listed = true; note('listed'); }
    return send({ jsonrpc: '2.0', id: m.id, result: { tools: tools.map(name => ({
      name, description: `Synthetic compatibility ${name} fixture; call once with {} only.`,
      inputSchema: { type: 'object', properties: {}, additionalProperties: false }
    })) } });
  }
  if (m.method === 'tools/call') {
    if (!initialized || !listed || !tools.includes(p.name) || !object(p.arguments) || Object.keys(p.arguments).length
        || called.has(p.name)) return stop('invalid_call');
    called.add(p.name); note(`executed_${p.name}`);
    if (p.name === 'stall') return; // Intentionally unanswered, for host cancellation.
    return send({ jsonrpc: '2.0', id: m.id, result: {
      content: [{ type: 'text', text: p.name === 'allow' ? 'OPENBOTS_ALLOWED' : 'OPENBOTS_DENY_EXECUTED' }]
    } });
  }
  send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'Fixture method unavailable' } });
}
note('started');
setTimeout(() => stop('deadline'), 125000).unref();
process.stdin.on('data', chunk => {
  if ((input += chunk.length) > MAX_INPUT) return stop('input_limit');
  pending = Buffer.concat([pending, chunk]);
  let index;
  while (!closed && (index = pending.indexOf(10)) !== -1) {
    if (index >= MAX_LINE) return stop('line_limit');
    const line = pending.subarray(0, index); pending = pending.subarray(index + 1); receive(line);
  }
  if (pending.length >= MAX_LINE) stop('line_limit');
});
process.stdin.on('end', () => stop(pending.length ? 'invalid_input' : 'stdin_closed', pending.length ? 2 : 0));
process.stdin.on('error', () => stop('stdin_error'));
process.stdout.on('error', () => stop('stdout_error'));
process.on('SIGTERM', () => stop('terminated', 0));
process.on('SIGINT', () => stop('terminated', 0));
