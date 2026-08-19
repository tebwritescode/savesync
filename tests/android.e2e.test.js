#!/usr/bin/env node
//
// Android end-to-end orchestrator.
//
//   node tests/android.e2e.test.js
//
// Boots the real self-hosted backend, then hands its setup code to
// tests/android.e2e_client.lua, which drives the shipping sync transport
// with the Android APK's exact surface: the REAL vendored luasocket over a
// raw TCP socket, no lua-https, no curl.
//
// Needs `luajit` on PATH and a gen1recomp checkout for the vendored
// luasocket sources -- $GEN1RECOMP or the default engine path.

'use strict';

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORT = 8811;

const ENGINE = process.env.GEN1RECOMP
  || 'C:/Users/User/Projects/gen1recomp-engine';
const LUASOCKET = path.join(ENGINE,
  'mobile/android/love/src/jni/love/src/libraries/luasocket/libluasocket');

if (!fs.existsSync(path.join(LUASOCKET, 'http.lua'))) {
  console.error('vendored luasocket not found at ' + LUASOCKET
    + ' -- set GEN1RECOMP to a gen1recomp checkout');
  process.exit(1);
}

function waitFor(url, deadlineMs = 10000) {
  const until = Date.now() + deadlineMs;
  return (async () => {
    while (Date.now() < until) {
      try {
        const res = await fetch(url);
        if (res.ok || res.status === 401) return true;
      } catch (_) { /* not up yet */ }
      await new Promise((r) => setTimeout(r, 100));
    }
    return false;
  })();
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'savesync-android-'));

  const server = spawn(process.execPath,
    [path.join(__dirname, '..', 'server', 'server.js')], {
      env: Object.assign({}, process.env, {
        PORT: String(PORT),
        DATA_DIR: dataDir,
        PUBLIC_URL: `http://127.0.0.1:${PORT}`,
        SERVER_NAME: 'android e2e',
      }),
      stdio: ['ignore', 'inherit', 'inherit'],
    });

  let code = 1;
  try {
    if (!await waitFor(`http://127.0.0.1:${PORT}/v1/hello`)) {
      throw new Error('server did not come up');
    }
    const codeFile = path.join(dataDir, 'setup-code.txt');
    if (!fs.existsSync(codeFile)) throw new Error('no setup code written');

    const run = spawnSync('luajit',
      ['tests/android.e2e_client.lua', codeFile, LUASOCKET],
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
