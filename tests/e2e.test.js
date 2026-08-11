#!/usr/bin/env node
//
// End-to-end orchestrator.
//
//   node tests/e2e.test.js
//
// Boots the real self-hosted backend plus a tiny header-echo server, then
// hands both URLs to tests/e2e_client.lua, which drives two devices through
// the real sync engine, the real HTTP worker and real curl.
//
// Needs `luajit` and `curl` on PATH. Everything else is Node stdlib.

'use strict';

const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SAVE_PORT = 8801;
const ECHO_PORT = 8802;
// WHICH QUOTING BRANCH RUNS IS DECIDED BY THE HOST, NOT BY US.
//
// HostShell.quote has two branches: Windows wraps in double quotes (and
// deletes any double quotes inside), POSIX wraps in single quotes.  It is
// tempting to run both from one machine, but the command still goes through
// io.popen -> the HOST's shell, and cmd.exe does not understand '...' at all.
// Simulating the POSIX branch on Windows therefore tests nothing except that
// cmd.exe is confused by single quotes.
//
// So each host runs its own branch for real, and the suite says plainly which
// one it covered. Run it on Windows AND on a POSIX box to cover both.
//
// One token per run, because a token IS a storage namespace.
const HOST_IS_WINDOWS = process.platform === 'win32';
const RUNS = HOST_IS_WINDOWS
  ? [{ osName: 'Windows', token: 'e2e-token-run-windows' }]
  : [{ osName: process.platform === 'darwin' ? 'OS X' : 'Linux',
       token: 'e2e-token-run-posix' }];

function waitFor(url, deadlineMs = 10000) {
  const until = Date.now() + deadlineMs;
  return (async () => {
    while (Date.now() < until) {
      try {
        const res = await fetch(url);
        if (res.ok) return true;
      } catch (_) { /* not up yet */ }
      await new Promise((r) => setTimeout(r, 100));
    }
    return false;
  })();
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'savesync-e2e-'));
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'savesync-dev-'));

  // The header echo exists for one assertion: that a JSON value in a header
  // reaches the server unmangled. That is the Dropbox-API-Arg case, and it is
  // the bug the curl-config-file transport was written to prevent.
  const echo = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = JSON.stringify({
        headers: req.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(body);
    });
  });
  await new Promise((r) => echo.listen(ECHO_PORT, r));

  const server = spawn(process.execPath,
    [path.join(__dirname, '..', 'server', 'server.js')], {
      env: Object.assign({}, process.env, {
        PORT: String(SAVE_PORT),
        DATA_DIR: dataDir,
        SAVESYNC_TOKENS: RUNS.map((r) => r.token).join(','),
        PUBLIC_URL: `http://127.0.0.1:${SAVE_PORT}`,
        SERVER_NAME: 'E2E server',
      }),
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  let serverOut = '';
  server.stdout.on('data', (d) => { serverOut += d.toString(); });
  server.stderr.on('data', (d) => { serverOut += d.toString(); });

  let code = 1;
  try {
    if (!await waitFor(`http://127.0.0.1:${SAVE_PORT}/health`)) {
      console.log('FAIL: save server did not start\n' + serverOut);
      throw new Error('no server');
    }

    // Both HostShell.quote branches, from whichever machine is running this.
    // The Windows branch DELETES double quotes from an argument and the POSIX
    // branch escapes them; a transport that survives only one of those is a
    // transport that breaks on half the platforms this game ships to.
    code = 0;
    for (const [i, run] of RUNS.entries()) {
      const client = spawn('luajit', [
        path.join('tests', 'e2e_client.lua'),
        `http://127.0.0.1:${SAVE_PORT}`,
        run.token,
        `http://127.0.0.1:${ECHO_PORT}/echo`,
        `${workDir.replace(/\\/g, '/')}/run${i}`,
        run.osName,
      ], { cwd: path.join(__dirname, '..'), stdio: 'inherit' });
      code = (await new Promise((r) => client.on('close', r))) || code;
    }

    // Independent confirmation, straight from the server's own API rather
    // than from anything the client under test told us.
    console.log('');
    for (const run of RUNS) {
      const res = await fetch(`http://127.0.0.1:${SAVE_PORT}/v1/files`, {
        headers: { Authorization: `Bearer ${run.token}` },
      });
      const { files } = await res.json();
      const names = Object.keys(files).sort();
      const current = names.filter((n) => /^red-E2E00001\.(sav|json)$/.test(n));
      const history = names.filter((n) => /^red-E2E00001\.h\d+\.sav$/.test(n));
      const strays = names.filter((n) => !n.startsWith('red-E2E00001.'));

      console.log(`[${run.osName}] server holds: ${names.join(', ')}`);
      if (current.length !== 2) {
        console.log(`FAIL [${run.osName}]: expected a .sav and a .json, got ${current.join(', ')}`);
        code = code || 1;
      }
      if (history.length < 2) {
        console.log(`FAIL [${run.osName}]: expected history, got ${history.length}`);
        code = code || 1;
      }
      // The "only save data leaves the machine" guarantee, checked against
      // what actually landed on a server rather than against an intention.
      if (strays.length) {
        console.log(`FAIL [${run.osName}]: unexpected uploads: ${strays.join(', ')}`);
        code = code || 1;
      }
    }
  } finally {
    // Wait for the child to actually exit before returning: killing it and
    // calling process.exit in the same tick trips a libuv assertion on
    // Windows, which reads like a test failure and is not one.
    const gone = new Promise((r) => server.once('close', r));
    server.kill();
    await gone;
    await new Promise((r) => echo.close(r));
    await new Promise((r) => setImmediate(r));
    for (const dir of [dataDir, workDir]) {
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
    }
  }

  console.log(code === 0 ? 'e2e: PASS' : 'e2e: FAIL');
  // Set the code and let the loop drain rather than calling process.exit:
  // forcing an exit while libuv still holds handles for the killed child and
  // the closed server trips an assertion on Windows that reads like a test
  // failure and is not one.
  process.exitCode = code === 0 ? 0 : 1;
})();
