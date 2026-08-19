#!/usr/bin/env node
//
// Live end-to-end orchestrator.
//
//   node tests/live.e2e.test.js
//
// Boots the REAL gen1mmo-server (the sibling checkout, or $GEN1MMO_SERVER)
// with an ephemeral data dir and test-strength PoW, reads the identity pin
// off its own log line, and hands host/port/pin to the Lua client -- which
// runs the shipped serverlink/net/tunnel stack over a real TCP socket.
//
// Needs `luajit` on PATH and Node 24+ (the server is type-stripped TS).

'use strict';

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORT = 8821;
const SERVER = process.env.GEN1MMO_SERVER
  || 'C:/Users/User/Projects/gen1mmo-server';

if (!fs.existsSync(path.join(SERVER, 'src', 'main.ts'))) {
  console.error('gen1mmo-server not found at ' + SERVER
    + ' -- set GEN1MMO_SERVER to a checkout');
  process.exit(1);
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'savesync-live-'));

  let pin = null;
  const server = spawn(process.execPath, [path.join(SERVER, 'src', 'main.ts')], {
    cwd: SERVER,
    env: Object.assign({}, process.env, {
      G1MMO_PORT: String(PORT),
      G1MMO_DATA: dataDir,
      G1MMO_POW_BITS: '8',          // seconds, not minutes, of proof
      G1MMO_ALLOW_GUESTS: '0',
      G1MMO_ALLOW_PLAINTEXT: '0',   // production posture: tunnel required
    }),
    stdio: ['ignore', 'pipe', 'inherit'],
  });

  const pinReady = new Promise((resolve) => {
    let buf = '';
    server.stdout.on('data', (chunk) => {
      buf += String(chunk);
      process.stdout.write(String(chunk));
      const m = buf.match(/identity pin: (\S+)/);
      if (m) { pin = m[1]; resolve(); }
    });
  });

  let code = 1;
  try {
    await Promise.race([
      pinReady,
      new Promise((_, rej) => setTimeout(() => rej(new Error('no pin line within 15s')), 15000)),
    ]);
    // give the listener a beat after the pin line
    await new Promise((r) => setTimeout(r, 300));

    const run = spawnSync('luajit',
      ['tests/live.e2e_client.lua', '127.0.0.1', String(PORT), pin],
      { stdio: 'inherit', cwd: path.join(__dirname, '..') });
    code = run.status === null ? 1 : run.status;
  } catch (err) {
    console.error(String(err && err.message || err));
  } finally {
    server.kill();
    try { fs.rmSync(dataDir, { recursive: true, force: true }); } catch (_) {}
  }
  process.exit(code);
})();
