#!/usr/bin/env node
//
// End-to-end test for the self-hosted backend: boots the real server against
// a throwaway data directory and drives it over real HTTP, the same way the
// mod's `server` provider does.
//
//   node tests/server.test.js
//
// Node standard library only, to match the thing it is testing.

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORT = 8799;
const BASE = `http://127.0.0.1:${PORT}`;
const TOKEN = 'test-token-please-ignore';

let passed = 0;
let failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; return; }
  failed++;
  console.log(`FAIL: ${name}${detail ? '  -- ' + detail : ''}`);
}
function eq(name, got, want) {
  check(name, got === want, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

async function req(method, url, { body, token = TOKEN, raw = false } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(BASE + url, { method, headers, body });
  const text = await res.text();
  if (raw) return { status: res.status, text };
  let json = null;
  try { json = JSON.parse(text); } catch (_) { /* not json, leave null */ }
  return { status: res.status, json, text };
}

async function waitForServer(deadlineMs = 10000) {
  const until = Date.now() + deadlineMs;
  while (Date.now() < until) {
    try {
      const res = await fetch(BASE + '/health');
      if (res.ok) return true;
    } catch (_) { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1cs-test-'));
  const child = spawn(process.execPath,
    [path.join(__dirname, '..', 'server', 'server.js')], {
      env: Object.assign({}, process.env, {
        PORT: String(PORT),
        DATA_DIR: dataDir,
        CLOUDSAVE_TOKENS: TOKEN,
        PUBLIC_URL: BASE,
        SERVER_NAME: 'Test server',
      }),
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  let serverOut = '';
  child.stdout.on('data', (d) => { serverOut += d.toString(); });
  child.stderr.on('data', (d) => { serverOut += d.toString(); });

  try {
    check('server starts', await waitForServer(), serverOut);

    // ---- auth
    eq('no token is 401', (await req('GET', '/v1/hello', { token: null })).status, 401);
    eq('wrong token is 401',
      (await req('GET', '/v1/hello', { token: 'nope' })).status, 401);
    eq('health needs no token',
      (await req('GET', '/health', { token: null })).status, 200);

    // ---- hello
    const hello = await req('GET', '/v1/hello');
    eq('hello ok', hello.status, 200);
    eq('hello names the server', hello.json.name, 'Test server');

    // ---- empty store
    const empty = await req('GET', '/v1/files');
    eq('files starts empty', Object.keys(empty.json.files).length, 0);
    eq('missing file is 404', (await req('GET', '/v1/file/red-abc.sav')).status, 404);

    // ---- a batch write, exactly as the mod sends one
    const save = 'return {player={name="RED"},party={}}';
    const manifest = JSON.stringify({ v: 1, key: 'red-abc', hash: 'deadbeef', seq: 1 });
    const wrote = await req('POST', '/v1/batch', {
      body: JSON.stringify({
        files: {
          'red-abc.sav': save,
          'red-abc.json': manifest,
          'red-abc.h0001.sav': save,
        },
      }),
    });
    eq('batch write ok', wrote.status, 200);
    eq('batch reports writes', wrote.json.wrote, 3);

    const listed = await req('GET', '/v1/files');
    eq('three files listed', Object.keys(listed.json.files).length, 3);
    eq('size is recorded', listed.json.files['red-abc.sav'], Buffer.byteLength(save));

    const got = await req('GET', '/v1/file/red-abc.sav', { raw: true });
    eq('read back byte-identical', got.text, save);

    // ---- update and delete in one batch (the prune path)
    const save2 = save + ' -- later';
    const second = await req('POST', '/v1/batch', {
      body: JSON.stringify({
        files: { 'red-abc.sav': save2, 'red-abc.h0001.sav': null },
      }),
    });
    eq('update+delete ok', second.status, 200);
    eq('reports the delete', second.json.deleted, 1);
    eq('overwrite took',
      (await req('GET', '/v1/file/red-abc.sav', { raw: true })).text, save2);
    eq('deleted file is gone',
      (await req('GET', '/v1/file/red-abc.h0001.sav')).status, 404);

    // ---- deleting something absent is not an error: pruning history must
    // never be able to fail a sync
    eq('deleting an absent file is fine', (await req('POST', '/v1/batch', {
      body: JSON.stringify({ files: { 'red-abc.h0009.sav': null } }),
    })).status, 200);

    // ---- name validation: no traversal, no slashes, no empties
    for (const bad of ['../escape', 'a/b', '..', '', '.hidden', 'x'.repeat(200)]) {
      const res = await req('POST', '/v1/batch', {
        body: JSON.stringify({ files: { [bad]: 'x' } }),
      });
      check(`rejects name ${JSON.stringify(bad)}`, res.status === 400,
        `got ${res.status}`);
    }
    eq('rejects traversal on read',
      (await req('GET', '/v1/file/' + encodeURIComponent('../tokens.json'))).status,
      400);

    // ---- a bad name anywhere rejects the WHOLE batch, so the store is
    // never left half-updated
    const mixed = await req('POST', '/v1/batch', {
      body: JSON.stringify({ files: { 'good-one.sav': 'yes', 'bad/name': 'no' } }),
    });
    eq('mixed batch rejected', mixed.status, 400);
    eq('and wrote nothing', (await req('GET', '/v1/file/good-one.sav')).status, 404);

    // ---- size ceiling
    const huge = await req('POST', '/v1/batch', {
      body: JSON.stringify({ files: { 'big.sav': 'x'.repeat(1024 * 1024 + 1) } }),
    });
    eq('oversized file rejected', huge.status, 413);

    // ---- malformed input
    eq('bad json rejected',
      (await req('POST', '/v1/batch', { body: '{nope' })).status, 400);
    eq('missing files rejected',
      (await req('POST', '/v1/batch', { body: '{}' })).status, 400);

    // ---- a token is the only key to a store
    eq('an unknown token cannot read',
      (await req('GET', '/v1/files', { token: 'nope' })).status, 401);

    // ---- the setup code the operator is told to paste
    check('setup code was printed', serverOut.includes('G1CS1.'), serverOut);
    const codeFile = path.join(dataDir, 'setup-code.txt');
    check('setup code was written to /data', fs.existsSync(codeFile));
    const code = fs.readFileSync(codeFile, 'utf8').trim();
    const payload = JSON.parse(
      Buffer.from(code.slice('G1CS1.'.length), 'base64url').toString('utf8'));
    eq('setup code names this provider', payload.provider, 'server');
    eq('setup code carries the url', payload.url, BASE);
    eq('setup code carries the token', payload.token, TOKEN);
  } finally {
    // Wait for the child to actually go before exiting: killing it and
    // calling process.exit in the same tick trips a libuv assertion on
    // Windows, which looks like a test failure and is not one.
    const gone = new Promise((r) => child.once('close', r));
    child.kill();
    await gone;
    try { fs.rmSync(dataDir, { recursive: true, force: true }); } catch (_) {}
  }

  console.log(`${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
})();
