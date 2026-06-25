#!/usr/bin/env node
'use strict';
// claude-portal: a minimal web chat UI in front of `claude` (Claude Code).
// Zero npm dependencies -- Node built-ins only. Spawns:
//   claude -p --output-format stream-json --verbose [--resume <id>]
// and relays parsed events to the browser via Server-Sent Events.

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '127.0.0.1';
const WORKDIR = process.env.WORKDIR || '/home/developer/workspace';
const STORE_DIR = process.env.STORE_DIR || path.join(os.homedir(), '.claude-portal');
const STORE_FILE = path.join(STORE_DIR, 'sessions.json');
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
const MAX_BODY = 1024 * 1024;

fs.mkdirSync(STORE_DIR, { recursive: true });

const INDEX = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');

function loadStore() {
  try { return JSON.parse(fs.readFileSync(STORE_FILE, 'utf8')); }
  catch { return { sessions: [] }; }
}
function saveStore(s) { fs.writeFileSync(STORE_FILE, JSON.stringify(s, null, 2)); }
function genId() { return 'cs_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }

function sendJSON(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (d) => { size += d.length; if (size > MAX_BODY) { reject(new Error('body too large')); req.destroy(); return; } chunks.push(d); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(INDEX);
    }

    if (req.method === 'GET' && url.pathname === '/api/sessions') {
      return sendJSON(res, 200, loadStore());
    }

    if (req.method === 'DELETE' && url.pathname.startsWith('/api/session/')) {
      const id = url.pathname.split('/').pop();
      const store = loadStore();
      store.sessions = store.sessions.filter((s) => s.id !== id);
      saveStore(store);
      return sendJSON(res, 200, { ok: true });
    }

    if (req.method === 'POST' && url.pathname === '/api/chat') {
      const body = JSON.parse((await readBody(req)) || '{}');
      const message = (body.message || '').toString();
      let sessionId = body.sessionId || null;
      if (!message.trim()) return sendJSON(res, 400, { error: 'empty message' });

      const store = loadStore();
      let session = sessionId ? store.sessions.find((s) => s.id === sessionId) : null;
      if (!session) {
        session = {
          id: genId(), claudeSessionId: null,
          title: message.slice(0, 60),
          createdAt: Date.now(), updatedAt: Date.now(),
          messages: [{ role: 'user', text: message, ts: Date.now() }],
        };
        store.sessions.unshift(session);
      } else {
        session.messages.push({ role: 'user', text: message, ts: Date.now() });
      }
      saveStore(store);
      sessionId = session.id;

      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
      });
      const sse = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
      sse('session', { id: sessionId, title: session.title });

      const args = ['-p', '--output-format', 'stream-json', '--verbose'];
      if (session.claudeSessionId) args.push('--resume', session.claudeSessionId);
      const child = spawn(CLAUDE_BIN, args, { cwd: WORKDIR, env: { ...process.env } });
      child.stdin.write(message);
      child.stdin.end();

      let assistantText = '';
      let buffer = '';
      const handleLine = (raw) => {
        const line = raw.trim();
        if (!line) return;
        let obj; try { obj = JSON.parse(line); } catch { return; }
        if (obj.type === 'system' && obj.subtype === 'init' && obj.session_id) {
          session.claudeSessionId = obj.session_id;
        } else if (obj.type === 'assistant' && obj.message && Array.isArray(obj.message.content)) {
          for (const block of obj.message.content) {
            if (block.type === 'text' && block.text) {
              assistantText += block.text;
              sse('text', { text: block.text });
            } else if (block.type === 'tool_use') {
              sse('tool', { name: block.name });
            }
          }
        } else if (obj.type === 'result') {
          sse('done', {
            result: obj.result || assistantText,
            usage: obj.usage, cost: obj.total_cost_usd,
            numTurns: obj.num_turns, isError: !!obj.is_error,
          });
        }
      };
      child.stdout.on('data', (d) => {
        buffer += d.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop();
        for (const ln of lines) handleLine(ln);
      });
      child.stderr.on('data', (d) => process.stderr.write(`[claude stderr] ${d}`));
      child.on('close', (code) => {
        if (buffer.trim()) handleLine(buffer);
        const st = loadStore();
        const s = st.sessions.find((x) => x.id === sessionId);
        if (s) {
          if (!s.claudeSessionId && session.claudeSessionId) s.claudeSessionId = session.claudeSessionId;
          s.messages.push({ role: 'assistant', text: assistantText, ts: Date.now() });
          s.updatedAt = Date.now();
          saveStore(st);
        }
        if (code !== 0) sse('error', { error: `claude exited with code ${code}` });
        res.end();
      });
      child.on('error', (e) => { sse('error', { error: String(e) }); res.end(); });
      req.on('close', () => { try { child.kill('SIGTERM'); } catch {} });
      return;
    }

    sendJSON(res, 404, { error: 'not found' });
  } catch (e) {
    try { sendJSON(res, 500, { error: String(e) }); } catch {}
  }
});

server.listen(PORT, HOST, () => {
  console.log(`claude-portal listening on http://${HOST}:${PORT} (workdir ${WORKDIR}, store ${STORE_DIR})`);
});
