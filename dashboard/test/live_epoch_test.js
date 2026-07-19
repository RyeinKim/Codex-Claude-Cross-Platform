'use strict';
//
// Epoch + monotonic-id test (zero real tokens, no browser). Locks the server
// half of the reconnect contract:
//   * a truncation (reset OR restart) MUST bump `epoch` and broadcast `reset`
//   * `_i` keeps climbing and is NEVER recycled across truncations
// so a reconnecting client can dedupe by `_i` and clear the old conversation
// on epoch change. (The client-side DOM clear lives in live.html.)
//
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MOCKS = path.join(ROOT, 'test', 'mocks');
const tmpLog = path.join(os.tmpdir(), 'live_epoch_' + process.pid + '.jsonl');
const PORT = 4292;

let server, fail = false;
const received = [], states = [], resets = [];
function ok(m) { console.log('  ✓ ' + m); }
function bad(m) { console.error('  ✗ ' + m); fail = true; }
function cleanup(code) { try { if (server) server.kill(); } catch (e) {} try { fs.unlinkSync(tmpLog); } catch (e) {} process.exit(code); }
function die(m) { bad(m); cleanup(1); }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

fs.writeFileSync(tmpLog, '');
server = spawn(process.execPath, [path.join(ROOT, 'dashboard', 'live-server.js')], {
  env: Object.assign({}, process.env, {
    BRIDGE_LOG: tmpLog, PORT: String(PORT),
    CLAUDE_BIN: path.join(MOCKS, 'mock-claude.sh'), CODEX_BIN: path.join(MOCKS, 'mock-codex.sh'),
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
        if (type === 'message') received.push(d);
        else if (type === 'state') states.push(d);
        else if (type === 'reset') resets.push(d);
      }
    });
  }).on('error', () => die('cannot connect to /live-events'));
}

(async function main() {
  setTimeout(() => die('test timed out'), 15000);
  await sleep(800);
  connectSSE();
  await sleep(300);

  // --- conversation #1 -------------------------------------------------------
  await post({ type: 'start', topic: 'first convo', turnSleep: 0, maxTurns: 2, firstSpeaker: 'claude' });
  await sleep(2000);

  const conv1 = received.slice();
  if (conv1.length >= 1 && conv1.every((r) => typeof r._i === 'number' && typeof r.epoch === 'number'))
    ok('conversation #1 records carry both _i and epoch');
  else return die('conversation #1 records missing _i/epoch: ' + JSON.stringify(conv1));

  const epoch1 = conv1[0].epoch;
  if (conv1.every((r) => r.epoch === epoch1)) ok('conversation #1 shares one epoch (' + epoch1 + ')');
  else bad('conversation #1 epoch not stable: ' + JSON.stringify(conv1.map((r) => r.epoch)));
  const maxI1 = conv1.reduce((m, r) => Math.max(m, r._i), -1);

  // --- reset: truncate + bump epoch + broadcast reset ------------------------
  const resetsBefore = resets.length;
  await post({ type: 'reset' });
  await sleep(700);

  const newResets = resets.slice(resetsBefore);
  if (newResets.length >= 1) ok('reset command broadcasts a reset event');
  else bad('no reset event after the reset command');

  const resetEpoch = newResets.length ? newResets[newResets.length - 1].epoch : null;
  if (resetEpoch != null && resetEpoch > epoch1) ok('reset bumped epoch (' + epoch1 + ' -> ' + resetEpoch + ')');
  else bad('reset did not bump epoch (' + epoch1 + ' -> ' + resetEpoch + ')');

  if (fs.readFileSync(tmpLog, 'utf8') === '') ok('log truncated to empty after reset (sole writer)');
  else bad('log not empty after reset');

  // --- conversation #2 -------------------------------------------------------
  const before2 = received.length;
  await post({ type: 'start', topic: 'second convo', turnSleep: 0, maxTurns: 2, firstSpeaker: 'claude' });
  await sleep(2000);

  const conv2 = received.slice(before2);
  if (conv2.length >= 1) ok('conversation #2 produced records'); else return die('conversation #2 produced no records');

  const epoch2 = conv2[0].epoch;
  if (epoch2 > resetEpoch) ok('restart bumped epoch again (' + resetEpoch + ' -> ' + epoch2 + ')');
  else bad('restart did not bump epoch (' + resetEpoch + ' -> ' + epoch2 + ')');

  const minI2 = conv2.reduce((m, r) => Math.min(m, r._i), Infinity);
  if (minI2 > maxI1) ok('_i stays monotonic across truncations — never recycled (' + maxI1 + ' -> ' + minI2 + ')');
  else bad('_i was recycled across a truncation (maxI1=' + maxI1 + ' minI2=' + minI2 + ')');

  const allI = received.map((r) => r._i);
  if (new Set(allI).size === allI.length) ok('every _i observed is unique (clients can dedupe)');
  else bad('duplicate _i observed: ' + JSON.stringify(allI));

  console.log('');
  if (fail) { console.error('❌ EPOCH TEST FAILED'); cleanup(1); }
  else { console.log('✅ EPOCH TEST PASSED'); cleanup(0); }
})();
