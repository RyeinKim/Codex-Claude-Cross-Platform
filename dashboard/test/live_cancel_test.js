'use strict';
//
// Cancellation test: Stop during an in-flight (slow) turn must KILL the child
// and drop its stale reply — no ghost turn lands in the log after Stop.
// Covers the adversarial-review high/medium concurrency findings.
//
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MOCKS = path.join(ROOT, 'test', 'mocks');
const tmpLog = path.join(os.tmpdir(), 'live_cancel_' + process.pid + '.jsonl');
const PORT = 4291;

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
    CLAUDE_BIN: path.join(MOCKS, 'slow-claude.sh'), CODEX_BIN: path.join(MOCKS, 'mock-codex.sh'),
    SLOW_SECS: '2',
  }),
  stdio: 'ignore',
});

function post(cmd) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(cmd);
    const r = http.request({ host: '127.0.0.1', port: PORT, path: '/control', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } },
      (resp) => { resp.resume(); resp.on('end', resolve); });
    r.on('error', reject); r.write(data); r.end();
  });
}
function connectSSE() {
  http.get({ host: '127.0.0.1', port: PORT, path: '/live-events' }, (res) => {
    res.setEncoding('utf8'); let buf = '';
    res.on('data', (ch) => { buf += ch; let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const frame = buf.slice(0, i); buf = buf.slice(i + 2);
        const ev = /^event: (.*)$/m.exec(frame); const dm = /^data: (.*)$/m.exec(frame);
        if (!dm) continue; let d; try { d = JSON.parse(dm[1]); } catch (e) { continue; }
        const type = ev ? ev[1] : 'message';
        if (type === 'message') received.push(d); else if (type === 'state') states.push(d);
      }
    });
  }).on('error', () => die('cannot connect to /live-events'));
}

(async function main() {
  setTimeout(() => die('test timed out'), 12000);
  await sleep(800);
  connectSSE();
  await sleep(300);

  await post({ type: 'start', topic: 'seed', turnSleep: 0, maxTurns: 0, firstSpeaker: 'claude' });
  await sleep(600);                        // claude turn is now in flight (2s sleep)
  const busyMidTurn = states.some((s) => s.busy === true);
  if (busyMidTurn) ok('turn is in flight (busy=true) after start'); else bad('never observed busy=true');

  await post({ type: 'stop' });            // kill the in-flight child
  await sleep(2200);                        // past when the slow reply would have completed

  const aiTurns = received.filter((r) => r.role === 'claude' || r.role === 'codex');
  if (aiTurns.length === 0) ok('Stop killed the in-flight turn — no ghost reply appended'); else bad('ghost AI turn(s) appended after Stop: ' + JSON.stringify(aiTurns.map((r) => r.role)));

  const onlySeed = received.length === 1 && received[0].role === 'human';
  if (onlySeed) ok('log holds only the human seed after cancellation'); else bad('unexpected log contents: ' + JSON.stringify(received.map((r) => r.role)));

  const last = states[states.length - 1];
  if (last && last.busy === false && last.running === false) ok('final state is idle (busy=false, running=false)'); else bad('final state not idle: ' + JSON.stringify(last));

  console.log('');
  if (fail) { console.error('❌ CANCELLATION TEST FAILED'); cleanup(1); }
  else { console.log('✅ CANCELLATION TEST PASSED'); cleanup(0); }
})();
