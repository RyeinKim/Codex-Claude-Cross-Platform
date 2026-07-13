'use strict';
//
// End-to-end test of the PUSH mechanism (zero real tokens, no browser):
//   1. boot server.js against a temp log,
//   2. connect to /events, receive the backlog,
//   3. append a new line to the log,
//   4. assert it is pushed live (fs.watch), with _i indices for dedupe.
//
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpLog = path.join(os.tmpdir(), 'sse_test_' + process.pid + '.jsonl');
const PORT = 4199;
let server;

function cleanup(code) {
  try { if (server) server.kill(); } catch (e) {}
  try { fs.unlinkSync(tmpLog); } catch (e) {}
  process.exit(code);
}
function fail(msg) { console.error('  ✗ ' + msg); cleanup(1); }
function ok(msg) { console.log('  ✓ ' + msg); }

// seed one backlog line
fs.writeFileSync(tmpLog, JSON.stringify({ ts: 't0', role: 'human', text: 'seed topic' }) + '\n');

server = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
  env: Object.assign({}, process.env, { BRIDGE_LOG: tmpLog, PORT: String(PORT), BACKSTOP_MS: '500' }),
  stdio: 'ignore',
});

const received = [];

setTimeout(function connectSSE() {
  const req = http.get({ host: '127.0.0.1', port: PORT, path: '/events' }, (res) => {
    res.setEncoding('utf8');
    let buf = '';
    res.on('data', (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf('\n\n')) >= 0) {
        const frame = buf.slice(0, idx); buf = buf.slice(idx + 2);
        const m = /^data: (.*)$/m.exec(frame);
        if (m) { try { received.push(JSON.parse(m[1])); } catch (e) {} }
      }
    });
  });
  req.on('error', () => fail('could not connect to /events (server booted?)'));

  // once connected, append a new line and expect it to be pushed
  setTimeout(() => {
    fs.appendFileSync(tmpLog, JSON.stringify({ ts: 't1', role: 'claude', text: 'hello from claude' }) + '\n');
  }, 400);

  // assert
  setTimeout(() => {
    const texts = received.map((r) => r.text);
    if (texts.indexOf('seed topic') < 0) return fail('did not receive backlog message (seed topic)');
    ok('received backlog message on connect');
    if (texts.indexOf('hello from claude') < 0) return fail('appended line was NOT pushed live');
    ok('received appended message via live push (fs.watch)');
    if (!received.every((r) => typeof r._i === 'number')) return fail('messages missing _i index for dedupe');
    ok('all messages carry _i index for dedupe');
    console.log('\n✅ SSE DASHBOARD TEST PASSED');
    cleanup(0);
  }, 1800);
}, 700);

setTimeout(() => fail('test timed out'), 6000);
