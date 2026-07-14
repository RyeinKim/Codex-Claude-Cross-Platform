#!/usr/bin/env node
'use strict';
//
// Stage B — interactive server. The human joins the conversation live and drives
// the controls. Zero dependencies (Node built-ins only).
//
//   server -> browser : SSE   (/live-events)   push messages + state
//   browser -> server : POST  (/control)       start / stop / say / step / config / reset
//
// Orchestration reuses the hardened turn logic via `bridge.sh --once <speaker>`,
// so personas, error handling, the injection guard, and timeouts live in one
// place. This server is the SOLE writer of the log.
//
// Concurrency model (hardened after adversarial review):
//   * every /control command runs through a single serialized queue (no
//     interleaving of command handlers -> no double-start / TOCTOU races)
//   * an in-flight turn is tracked and KILLED on stop/reset/start; a run
//     generation counter makes the aborted turn drop its (now stale) reply
//   * each log record carries a monotonic `_i` (never recycled) and an `epoch`
//     (bumped per new conversation) so a reconnecting client never drops or
//     duplicates messages and clears the old conversation on epoch change
//   * bind to loopback only; validate + clamp all inputs; no unhandled rejects
//
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const BRIDGE = process.env.BRIDGE_BIN || path.join(ROOT, 'bridge.sh');
const LOG = process.env.BRIDGE_LOG || path.join(ROOT, 'conversation.jsonl');
const PORT = parseInt(process.env.PORT || '4200', 10);
const HOST = process.env.HOST || '127.0.0.1';   // loopback only — do not expose the control plane
const PUBLIC = path.join(__dirname, 'public');
const MAX_TURNS_CAP = 100000;
const MAX_SLEEP = 300;

let clients = [];
let nextId = 0;          // monotonic message id, persisted per record, NEVER reset
let epoch = 0;           // conversation generation, bumped on truncate
let currentChild = null; // the in-flight `bridge --once` process, if any
let runGen = 0;          // bumped on cancel; doTurn compares to detect an aborted turn
let loopActive = false;
let pendingReply = false;// a paused 'say' that arrived mid-turn, owed one reply
let speakerOverride = null;

const state = { running: false, busy: false, nextSpeaker: 'claude', turnSleep: 6, maxTurns: 0, turnCount: 0 };

// ---- log + SSE --------------------------------------------------------------
function readLines() {
  let raw;
  try { raw = fs.readFileSync(LOG, 'utf8'); } catch (e) { return []; }
  const out = [];
  for (const line of raw.split('\n')) { if (!line) continue; try { out.push(JSON.parse(line)); } catch (e) {} }
  return out;
}
function sse(res, event, obj) { res.write('event: ' + event + '\ndata: ' + JSON.stringify(obj) + '\n\n'); }
function broadcast(event, obj) { for (const c of clients) sse(c, event, obj); }
function publicState() {
  return { running: state.running, busy: state.busy, nextSpeaker: state.nextSpeaker,
           turnSleep: state.turnSleep, maxTurns: state.maxTurns, turnCount: state.turnCount, epoch: epoch };
}
function broadcastState() { broadcast('state', publicState()); }

function appendTurn(role, text) {
  const rec = { ts: new Date().toISOString(), role: role, text: text, _i: nextId++, epoch: epoch };
  try { fs.appendFileSync(LOG, JSON.stringify(rec) + '\n'); }
  catch (e) { broadcast('error', { message: 'log write failed: ' + String((e && e.message) || e) }); return false; }
  broadcast('message', rec);
  return true;
}
function truncateLog() { try { fs.writeFileSync(LOG, ''); } catch (e) {} epoch++; }   // bump epoch, keep nextId monotonic

// ---- orchestration ----------------------------------------------------------
function runOnce(speaker) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [BRIDGE, '--once', speaker], { env: Object.assign({}, process.env, { BRIDGE_LOG: LOG }) });
    currentChild = child;
    let out = '', err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', (e) => { if (currentChild === child) currentChild = null; reject(e); });
    child.on('close', (code, signal) => {
      if (currentChild === child) currentChild = null;
      if (signal) { reject(new Error('turn cancelled')); return; }
      if (code === 0 && out.trim()) resolve(out.trim());
      else reject(new Error(err.trim() || ('bridge --once ' + speaker + ' exited ' + code)));
    });
  });
}
function cancelActive() {          // invalidate + kill any in-flight turn
  runGen++;
  if (currentChild) { try { currentChild.kill(); } catch (e) {} currentChild = null; }
  state.busy = false;
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function interruptibleSleep(ms) {
  return new Promise((res) => {
    const start = Date.now();
    const iv = setInterval(() => { if (!state.running || Date.now() - start >= ms) { clearInterval(iv); res(); } }, 100);
  });
}

async function doTurn(speaker) {
  const gen = runGen;
  state.busy = true; broadcastState();
  let reply;
  try {
    reply = await runOnce(speaker);
  } catch (e) {
    if (runGen !== gen) return false;                 // cancelled — silent
    state.busy = false; state.running = false;
    broadcast('error', { message: String((e && e.message) || e) }); broadcastState();
    return false;
  }
  if (runGen !== gen) return false;                    // cancelled after resolve — drop the stale reply
  if (!appendTurn(speaker, reply)) { state.busy = false; state.running = false; broadcastState(); return false; }
  state.turnCount++;
  state.nextSpeaker = speakerOverride || (speaker === 'claude' ? 'codex' : 'claude');
  speakerOverride = null;
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
  const ok = await doTurn(state.nextSpeaker);
  // a 'say' that arrived while this turn was busy is owed exactly one reply
  while (ok && !state.running && pendingReply && !state.busy) { pendingReply = false; await doTurn(state.nextSpeaker); }
}

function bg(p) {   // run a background task; never let a rejection go unhandled
  Promise.resolve(p).catch((e) => {
    state.busy = false; state.running = false;
    broadcast('error', { message: String((e && e.message) || e) }); broadcastState();
  });
}

// ---- command handlers (serialized) ------------------------------------------
function clampSleep(v) { const n = Number(v); if (!isFinite(n)) return state.turnSleep; return Math.min(MAX_SLEEP, Math.max(0, n)); }
function clampTurns(v) { const n = Math.floor(Number(v)); if (!isFinite(n)) return state.maxTurns; return Math.min(MAX_TURNS_CAP, Math.max(0, n)); }

async function stopEverything() { cancelActive(); state.running = false; while (loopActive) await sleep(20); state.busy = false; pendingReply = false; }

async function cmdStart(cmd) {
  await stopEverything();
  truncateLog(); broadcast('reset', { epoch: epoch }); state.turnCount = 0; speakerOverride = null;
  if (cmd.firstSpeaker === 'claude' || cmd.firstSpeaker === 'codex') state.nextSpeaker = cmd.firstSpeaker;
  if (cmd.turnSleep != null) state.turnSleep = clampSleep(cmd.turnSleep);
  if (cmd.maxTurns != null) state.maxTurns = clampTurns(cmd.maxTurns);
  const topic = String(cmd.topic || '').trim() || 'Say hi and start chatting.';
  appendTurn('human', topic);
  state.running = true; broadcastState();
  bg(runLoop());
}
async function cmdStop() { cancelActive(); state.running = false; while (loopActive) await sleep(20); state.busy = false; broadcastState(); }
async function cmdReset() { await stopEverything(); truncateLog(); broadcast('reset', { epoch: epoch }); state.turnCount = 0; broadcastState(); }
function cmdSay(cmd) {
  const text = String(cmd.text || '').trim();
  if (!text) return;
  appendTurn('human', text);
  if (state.running) return;              // the running loop will pick it up next turn
  if (state.busy) { pendingReply = true; return; }  // a turn is mid-flight; owe one reply after it
  bg(stepOnce());
}
function cmdConfig(cmd) {
  if (cmd.turnSleep != null) state.turnSleep = clampSleep(cmd.turnSleep);
  if (cmd.maxTurns != null) state.maxTurns = clampTurns(cmd.maxTurns);
  if (cmd.nextSpeaker === 'claude' || cmd.nextSpeaker === 'codex') { state.nextSpeaker = cmd.nextSpeaker; speakerOverride = cmd.nextSpeaker; }
  broadcastState();
}

async function handleCommand(cmd) {
  if (!cmd || typeof cmd !== 'object') return;
  switch (cmd.type) {
    case 'start': return cmdStart(cmd);
    case 'stop': return cmdStop();
    case 'reset': return cmdReset();
    case 'say': return cmdSay(cmd);
    case 'step': if (!state.running && !state.busy) bg(stepOnce()); return;
    case 'config': return cmdConfig(cmd);
    default: broadcast('error', { message: 'unknown command: ' + cmd.type });
  }
}

// single serialized queue so command handlers never interleave
let cmdChain = Promise.resolve();
function enqueueCommand(cmd) {
  cmdChain = cmdChain.then(() => handleCommand(cmd)).catch((e) => broadcast('error', { message: String((e && e.message) || e) }));
}

// ---- HTTP -------------------------------------------------------------------
function handleEvents(req, res) {
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no' });
  res.write('retry: 2000\n\n');
  for (const m of readLines()) sse(res, 'message', m);   // records already carry _i + epoch
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
    enqueueCommand(cmd);
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
    const ct = ext === '.html' ? 'text/html; charset=utf-8' : ext === '.js' ? 'text/javascript' : ext === '.css' ? 'text/css' : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': ct }); res.end(buf);
  });
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/live-events') return handleEvents(req, res);
  if (url === '/control' && req.method === 'POST') return handleControl(req, res);
  return serveStatic(req, res);
});

// never crash the sole log-writer / SSE process on an unexpected error
process.on('unhandledRejection', (e) => { try { broadcast('error', { message: 'internal error' }); } catch (x) {} state.busy = false; state.running = false; });
process.on('uncaughtException', (e) => { try { broadcast('error', { message: 'internal error' }); } catch (x) {} });

// initialise monotonic id + epoch from any existing log
(function initIds() {
  const recs = readLines(); let mx = -1;
  for (const r of recs) {
    if (typeof r._i === 'number' && r._i > mx) mx = r._i;
    if (typeof r.epoch === 'number' && r.epoch > epoch) epoch = r.epoch;
  }
  nextId = mx >= 0 ? mx + 1 : recs.length;
})();

server.listen(PORT, HOST, () => {
  console.log('interactive dashboard → http://' + (HOST === '0.0.0.0' ? 'localhost' : HOST) + ':' + PORT);
  console.log('bridge                → ' + BRIDGE);
  console.log('log                   → ' + LOG);
});
