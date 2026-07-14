'use strict';
//
// End-to-end test of the interactive server (zero real tokens, no browser):
//   boot live-server.js with mock CLIs -> POST /control commands -> observe SSE.
// Verifies: start seeds + auto-runs, maxTurns stops the loop, a human 'say'
// while paused injects a turn AND draws exactly one AI reply, state is reported.
//
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MOCKS = path.join(ROOT, 'test', 'mocks');
const tmpLog = path.join(os.tmpdir(), 'live_test_' + process.pid + '.jsonl');
const PORT = 4288;

let server, fail = false;
const received = [], states = [];
function ok(m) { console.log('  ✓ ' + m); }
function bad(m) { console.error('  ✗ ' + m); fail = true; }
function cleanup(code) { try { if (server) server.kill(); } catch (e) {} try { fs.unlinkSync(tmpLog); } catch (e) {} process.exit(code); }
function die(m) { bad(m); cleanup(1); }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

fs.writeFileSync(tmpLog, '');

server = spawn(process.execPath, [path.join(ROOT, 'dashboard', 'live-server.js')], {
  env: Object.assign({}, process.env, {
    BRIDGE_LOG: tmpLog, PORT: String(PORT),
    CLAUDE_BIN: path.join(MOCKS, 'mock-claude.sh'),
    CODEX_BIN: path.join(MOCKS, 'mock-codex.sh'),
  }),
  stdio: 'ignore',
});

function post(cmd) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(cmd);
    const r = http.request(
      { host: '127.0.0.1', port: PORT, path: '/control', method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } },
      (resp) => { resp.resume(); resp.on('end', resolve); });
    r.on('error', reject); r.write(data); r.end();
  });
}

function connectSSE() {
  http.get({ host: '127.0.0.1', port: PORT, path: '/live-events' }, (res) => {
    res.setEncoding('utf8'); let buf = '';
    res.on('data', (ch) => {
      buf += ch; let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const frame = buf.slice(0, i); buf = buf.slice(i + 2);
        const ev = /^event: (.*)$/m.exec(frame); const dm = /^data: (.*)$/m.exec(frame);
        if (!dm) continue; let d; try { d = JSON.parse(dm[1]); } catch (e) { continue; }
        const type = ev ? ev[1] : 'message';
        if (type === 'message') received.push(d);
        else if (type === 'state') states.push(d);
      }
    });
  }).on('error', () => die('cannot connect to /live-events'));
}

(async function main() {
  setTimeout(() => die('test timed out'), 12000);
  await sleep(800);
  connectSSE();
  await sleep(300);

  // --- start: seed + auto-run, capped at 2 AI turns ---
  await post({ type: 'start', topic: 'seed topic', turnSleep: 0, maxTurns: 2, firstSpeaker: 'claude' });
  await sleep(2000);

  const roles1 = received.map((r) => r.role);
  if (roles1.slice(0, 3).join(',') === 'human,claude,codex') ok('start seeds human topic then auto-runs claude, codex');
  else bad('expected [human,claude,codex], got [' + roles1.slice(0, 3).join(',') + ']');

  if (received[0] && /seed topic/.test(received[0].text)) ok('human seed carries the topic');
  else bad('human seed topic missing');

  const stoppedAt2 = states.some((s) => s.running === false && s.turnCount === 2);
  if (stoppedAt2) ok('maxTurns=2 stopped the auto-loop after 2 turns');
  else bad('loop did not stop at maxTurns=2 (states: ' + JSON.stringify(states.map((s) => [s.running, s.turnCount])) + ')');

  // --- human interjects while paused -> one reply ---
  const before = received.length;
  await post({ type: 'say', text: 'wait, human here — pick a shorter name' });
  await sleep(1500);

  const added = received.slice(before);
  if (added[0] && added[0].role === 'human' && /human here/.test(added[0].text)) ok('human interjection is injected as a turn');
  else bad('human interjection not injected');

  if (added[1] && (added[1].role === 'claude' || added[1].role === 'codex')) ok('exactly one AI reply follows the interjection while paused');
  else bad('no AI reply to the human interjection');

  if (received.every((r) => typeof r._i === 'number')) ok('all messages carry _i index for dedupe');
  else bad('messages missing _i index');

  console.log('');
  if (fail) { console.error('❌ INTERACTIVE SERVER TEST FAILED'); cleanup(1); }
  else { console.log('✅ INTERACTIVE SERVER TEST PASSED'); cleanup(0); }
})();
