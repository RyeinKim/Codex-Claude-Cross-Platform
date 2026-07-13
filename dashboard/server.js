#!/usr/bin/env node
'use strict';
//
// Stage A dashboard server — zero dependencies (Node built-ins only).
//
// Streams the bridge's conversation.jsonl to the browser over SSE. We own the
// writer (bridge.sh), so this is PUSH, not poll: fs.watch fires on append and
// we broadcast the new line. A low-frequency interval is only a safety backstop
// in case an fs event is ever missed.
//
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const LOG = process.env.BRIDGE_LOG || path.join(ROOT, 'conversation.jsonl');
const PORT = parseInt(process.env.PORT || '4100', 10);
const PUBLIC = path.join(__dirname, 'public');
const BACKSTOP_MS = parseInt(process.env.BACKSTOP_MS || '1000', 10);

let clients = [];      // open SSE responses
let sentCount = 0;     // how many valid lines we've already broadcast
let lastSize = 0;      // last known file size (to detect truncation = new run)

function readLines() {
  let raw;
  try { raw = fs.readFileSync(LOG, 'utf8'); } catch (e) { return []; }
  const out = [];
  const parts = raw.split('\n');
  for (const line of parts) {
    if (!line) continue;
    try { out.push(JSON.parse(line)); } catch (e) { /* skip partial/invalid line */ }
  }
  return out;
}

function sse(res, event, obj) {
  res.write('event: ' + event + '\ndata: ' + JSON.stringify(obj) + '\n\n');
}

// Detect new lines / truncation and broadcast. Runs synchronously so it never
// interleaves with a client connecting (Node is single-threaded).
function pump() {
  let size;
  try { size = fs.statSync(LOG).size; } catch (e) { return; }
  if (size < lastSize) {                 // file shrank -> bridge started a new run
    sentCount = 0;
    for (const c of clients) sse(c, 'reset', {});
  }
  lastSize = size;
  const lines = readLines();
  for (let i = sentCount; i < lines.length; i++) {
    const msg = Object.assign({ _i: i }, lines[i]);
    for (const c of clients) sse(c, 'message', msg);
  }
  sentCount = lines.length;
}

function handleEvents(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.write('retry: 2000\n\n');
  // Backlog first, then register for live pushes. Synchronous, so pump() cannot
  // interleave -> the new client gets 0..K-1 here and K.. via pump with no gap.
  const lines = readLines();
  for (let i = 0; i < lines.length; i++) sse(res, 'message', Object.assign({ _i: i }, lines[i]));
  clients.push(res);
  const ka = setInterval(() => { try { res.write(': ping\n\n'); } catch (e) {} }, 25000);
  req.on('close', () => {
    clearInterval(ka);
    clients = clients.filter((c) => c !== res);
  });
}

function serveStatic(req, res) {
  let rel = req.url.split('?')[0];
  if (rel === '/') rel = '/index.html';
  const fp = path.join(PUBLIC, path.normalize(rel));
  if (fp.indexOf(PUBLIC) !== 0) { res.writeHead(403); return res.end('forbidden'); }
  fs.readFile(fp, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    const ext = path.extname(fp);
    const ct = ext === '.html' ? 'text/html; charset=utf-8'
             : ext === '.js' ? 'text/javascript'
             : ext === '.css' ? 'text/css'
             : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': ct });
    res.end(buf);
  });
}

const server = http.createServer((req, res) => {
  if (req.url.split('?')[0] === '/events') return handleEvents(req, res);
  return serveStatic(req, res);
});

server.listen(PORT, () => {
  console.log('dashboard  → http://localhost:' + PORT);
  console.log('watching   → ' + LOG);
});

// Start watching: fs.watch on the directory (survives file re-creation/truncation),
// plus a low-frequency backstop.
try {
  const dir = path.dirname(LOG);
  const base = path.basename(LOG);
  fs.watch(dir, (evt, fname) => { if (!fname || fname === base) pump(); });
} catch (e) { /* directory may not exist yet; backstop still covers it */ }
setInterval(pump, BACKSTOP_MS);
pump();
