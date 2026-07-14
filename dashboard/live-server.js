#!/usr/bin/env node
'use strict';
//
// Stage B — interactive server. The human joins the conversation live and drives
// the controls. Zero dependencies (Node built-ins only).
//
//   server -> browser : SSE   (/live-events)   push messages + state
//   browser -> server : POST  (/control)       start / stop / say / step / config
//
// Orchestration reuses the hardened turn logic via `bridge.sh --once <speaker>`,
// so there is a single source of truth for personas, error handling, the
// injection guard, and timeouts. This server is the SOLE writer of the log.
//
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const BRIDGE = process.env.BRIDGE_BIN || path.join(ROOT, 'bridge.sh');
const LOG = process.env.BRIDGE_LOG || path.join(ROOT, 'conversation.jsonl');
const PORT = parseInt(process.env.PORT || '4200', 10);
const PUBLIC = path.join(__dirname, 'public');

let clients = [];
let lineIndex = 0;
let loopActive = false;

const state = {
  running: false,   // auto-loop active
  busy: false,      // an AI turn is in flight
  nextSpeaker: 'claude',
  turnSleep: 6,     // seconds between auto-turns
  maxTurns: 0,      // 0 = unlimited
  turnCount: 0,
};

// ---- log + SSE --------------------------------------------------------------
function readLines() {
  let raw;
  try { raw = fs.readFileSync(LOG, 'utf8'); } catch (e) { return []; }
  const out = [];
  for (const line of raw.split('\n')) {
    if (!line) continue;
    try { out.push(JSON.parse(line)); } catch (e) {}
  }
  return out;
}
function sse(res, event, obj) { res.write('event: ' + event + '\ndata: ' + JSON.stringify(obj) + '\n\n'); }
function broadcast(event, obj) { for (const c of clients) sse(c, event, obj); }
function publicState() {
  return {
    running: state.running, busy: state.busy, nextSpeaker: state.nextSpeaker,
    turnSleep: state.turnSleep, maxTurns: state.maxTurns, turnCount: state.turnCount,
  };
}
function broadcastState() { broadcast('state', publicState()); }

function appendTurn(role, text) {
  const line = { ts: new Date().toISOString(), role: role, text: text };
  fs.appendFileSync(LOG, JSON.stringify(line) + '\n');
  broadcast('message', Object.assign({ _i: lineIndex++ }, line));
}
function truncateLog() { try { fs.writeFileSync(LOG, ''); } catch (e) {} lineIndex = 0; }

// ---- orchestration ----------------------------------------------------------
function runOnce(speaker) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [BRIDGE, '--once', speaker], {
      env: Object.assign({}, process.env, { BRIDGE_LOG: LOG }),
    });
    let out = '', err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0 && out.trim()) resolve(out.trim());
      else reject(new Error(err.trim() || ('bridge --once ' + speaker + ' exited ' + code)));
    });
  });
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function interruptibleSleep(ms) {
  return new Promise((res) => {
    const start = Date.now();
    const iv = setInterval(() => {
      if (!state.running || Date.now() - start >= ms) { clearInterval(iv); res(); }
    }, 100);
  });
}

async function doTurn(speaker) {
  state.busy = true; broadcastState();
  let reply;
  try {
    reply = await runOnce(speaker);
  } catch (e) {
    state.busy = false; state.running = false;
    broadcast('error', { message: String((e && e.message) || e) });
    broadcastState();
    return false;
  }
  appendTurn(speaker, reply);
  state.turnCount++;
  state.nextSpeaker = speaker === 'claude' ? 'codex' : 'claude';
  state.busy = false; broadcastState();
  return true;
}

async function runLoop() {
  if (loopActive) return;
  loopActive = true;
  try {
    while (state.running) {
      if (state.maxTurns && state.turnCount >= state.maxTurns) { state.running = false; broadcastState(); break; }
      const ok = await doTurn(state.nextSpeaker);
      if (!ok) break;
      if (state.running) await interruptibleSleep(state.turnSleep * 1000);
    }
  } finally { loopActive = false; }
}

async function stepOnce() {
  if (state.busy) return;
  await doTurn(state.nextSpeaker);
}

function clampSleep(s) { s = Number(s); if (!isFinite(s)) return state.turnSleep; return Math.min(120, Math.max(0, s)); }

async function handleCommand(cmd) {
  switch (cmd && cmd.type) {
    case 'start': {
      if (state.busy) { broadcast('error', { message: 'A turn is in progress — try again in a moment.' }); return; }
      state.running = false;
      while (loopActive) await sleep(20);        // let any old loop unwind (fast; not busy)
      truncateLog(); broadcast('reset', {}); state.turnCount = 0;
      if (cmd.firstSpeaker === 'claude' || cmd.firstSpeaker === 'codex') state.nextSpeaker = cmd.firstSpeaker;
      if (cmd.turnSleep != null) state.turnSleep = clampSleep(cmd.turnSleep);
      if (cmd.maxTurns != null) state.maxTurns = Math.max(0, cmd.maxTurns | 0);
      const topic = String(cmd.topic || '').trim() || 'Say hi and start chatting.';
      appendTurn('human', topic);
      state.running = true; broadcastState();
      runLoop();
      return;
    }
    case 'stop': state.running = false; broadcastState(); return;
    case 'say': {
      const text = String(cmd.text || '').trim();
      if (!text) return;
      appendTurn('human', text);
      if (!state.running && !state.busy) stepOnce();   // paused: answer once
      return;
    }
    case 'step': if (!state.running) stepOnce(); return;
    case 'config': {
      if (cmd.turnSleep != null) state.turnSleep = clampSleep(cmd.turnSleep);
      if (cmd.maxTurns != null) state.maxTurns = Math.max(0, cmd.maxTurns | 0);
      if (cmd.nextSpeaker === 'claude' || cmd.nextSpeaker === 'codex') state.nextSpeaker = cmd.nextSpeaker;
      broadcastState();
      return;
    }
    case 'reset':
      state.running = false; truncateLog(); broadcast('reset', {}); state.turnCount = 0; broadcastState();
      return;
    default:
      broadcast('error', { message: 'unknown command: ' + (cmd && cmd.type) });
  }
}

// ---- HTTP -------------------------------------------------------------------
function handleEvents(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache',
    'Connection': 'keep-alive', 'X-Accel-Buffering': 'no',
  });
  res.write('retry: 2000\n\n');
  const lines = readLines();
  for (let i = 0; i < lines.length; i++) sse(res, 'message', Object.assign({ _i: i }, lines[i]));
  sse(res, 'state', publicState());
  clients.push(res);
  const ka = setInterval(() => { try { res.write(': ping\n\n'); } catch (e) {} }, 25000);
  req.on('close', () => { clearInterval(ka); clients = clients.filter((c) => c !== res); });
}

function handleControl(req, res) {
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
  req.on('end', () => {
    let cmd;
    try { cmd = JSON.parse(body || '{}'); } catch (e) { res.writeHead(400); return res.end('bad json'); }
    Promise.resolve().then(() => handleCommand(cmd)).catch((e) => broadcast('error', { message: String((e && e.message) || e) }));
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{"ok":true}');
  });
}

function serveStatic(req, res) {
  let rel = req.url.split('?')[0];
  if (rel === '/' || rel === '/live') rel = '/live.html';
  const fp = path.join(PUBLIC, path.normalize(rel));
  if (fp.indexOf(PUBLIC) !== 0) { res.writeHead(403); return res.end('forbidden'); }
  fs.readFile(fp, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    const ext = path.extname(fp);
    const ct = ext === '.html' ? 'text/html; charset=utf-8'
             : ext === '.js' ? 'text/javascript' : ext === '.css' ? 'text/css'
             : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': ct }); res.end(buf);
  });
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/live-events') return handleEvents(req, res);
  if (url === '/control' && req.method === 'POST') return handleControl(req, res);
  return serveStatic(req, res);
});

lineIndex = readLines().length;   // continue an existing log correctly
server.listen(PORT, () => {
  console.log('interactive dashboard → http://localhost:' + PORT);
  console.log('bridge                → ' + BRIDGE);
  console.log('log                   → ' + LOG);
});
