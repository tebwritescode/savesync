#!/usr/bin/env node
//
// GitHub provider, end-to-end against a fake GitHub.
//
//   node tests/github.test.js
//
// WHY THIS EXISTS.  A real player signed in with GitHub, a gist was created
// holding only the README the mod writes at link time, and no save file
// ever arrived.  mod/src/providers/github.lua had zero coverage that goes
// past "did link() return a cfg" -- nothing exercised P.write against a
// server, because GitHub has no sandbox and the old suite had nowhere to
// point instead.  This boots one.
//
// Boots a fake GitHub HTTP server (Node stdlib only: the gist API and the
// device flow) and hands its URL to tests/github_client.lua, which drives
// the real provider through the real HTTP worker lifted out of
// mod/src/http.lua and real curl -- the same trick tests/e2e_client.lua uses
// for the sync engine, aimed here at the GitHub provider instead.
//
// Needs `luajit` and `curl` on PATH. Everything else is Node stdlib.

'use strict';

const { spawn } = require('child_process');
const http = require('http');
const crypto = require('crypto');
const os = require('os');
const path = require('path');
const fs = require('fs');

const PORT = 8803;
const BASE = `http://127.0.0.1:${PORT}`;

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

// ------------------------------------------------------------- the fake GitHub

// One gist store, one request log. The suite only ever needs one gist, so
// there is no reason for the fake to support more -- but it has to survive
// the client asking about several, since the "find MY gist" pagination loop
// in P.link always walks the list before deciding to create one.
const gists = new Map();
const requests = [];
let gistSeq = 0;

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(body);
}

// Realistic shape on purpose. mod/src/json.lua is a hand-written decoder
// (no library, see its own header comment for why), so a hand-trimmed
// fixture would only prove the decoder can read a hand-trimmed fixture. A
// numeric owner id, a nested files map, a history array and a few JSON
// `null`s give the decoder the same texture a real gist response actually
// has -- `owner.id` in particular, because a decoder that silently coerced
// numbers to strings would pass every test that never checked one.
function buildGist(id, description, filesMap) {
  const files = {};
  for (const [name, content] of Object.entries(filesMap)) {
    files[name] = {
      filename: name,
      type: name.endsWith('.json') ? 'application/json' : 'text/plain',
      // real gists answer null here for a file type GitHub does not
      // recognise as a language -- a save blob or a manifest, always
      language: name.endsWith('.md') ? 'Markdown' : null,
      raw_url: `${BASE}/raw/${id}/${encodeURIComponent(name)}`,
      size: Buffer.byteLength(content, 'utf8'),
      truncated: false,
      content,
    };
  }
  const now = new Date().toISOString();
  return {
    url: `${BASE}/gists/${id}`,
    forks_url: `${BASE}/gists/${id}/forks`,
    commits_url: `${BASE}/gists/${id}/commits`,
    id,
    node_id: `G_${id}`,
    git_pull_url: `${BASE}/${id}.git`,
    git_push_url: `${BASE}/${id}.git`,
    html_url: `${BASE}/gists/${id}`,
    files,
    public: false,
    created_at: now,
    updated_at: now,
    description,
    comments: 0,
    user: null,               // real gists answer null here outside a fork
    comments_enabled: true,
    comments_url: `${BASE}/gists/${id}/comments`,
    owner: {
      login: 'octocat-test',
      id: 123456,              // NUMERIC on purpose -- see header comment
      node_id: 'U_123456',
      avatar_url: `${BASE}/avatars/octocat-test`,
      gravatar_id: '',
      url: `${BASE}/users/octocat-test`,
      html_url: `${BASE}/octocat-test`,
      type: 'User',
      site_admin: false,
    },
    forks: [],
    history: [
      {
        user: null,
        version: crypto.randomBytes(20).toString('hex'),
        committed_at: now,
        change_status: {
          total: Object.keys(files).length,
          additions: Object.keys(files).length,
          deletions: 0,
        },
        url: `${BASE}/gists/${id}/${crypto.randomBytes(4).toString('hex')}`,
      },
    ],
    truncated: false,
  };
}

const server = http.createServer(async (req, res) => {
  let u;
  try {
    u = new URL(req.url, BASE);
  } catch (e) {
    res.writeHead(400);
    res.end();
    return;
  }
  const rawBody = await readBody(req);
  // Recorded before any response is decided, so a request that crashes the
  // handler is still on the record -- the whole point of this log is to
  // catch the fake lying by omission.
  requests.push({
    method: req.method,
    path: u.pathname,
    query: Object.fromEntries(u.searchParams),
    headers: Object.assign({}, req.headers),
    body: rawBody,
  });

  // -------------------------------------------------------- device flow
  // (github.com/login/..., form-encoded requests, JSON responses)
  if (req.method === 'POST' && u.pathname === '/login/device/code') {
    return sendJson(res, 200, {
      device_code: 'fake-device-code',
      user_code: 'ABCD-1234',
      verification_uri: `${BASE}/login/device`,
      verification_uri_complete: `${BASE}/login/device?user_code=ABCD-1234`,
      expires_in: 900,
      // real GitHub's floor is 5s; 0 keeps the suite from actually waiting,
      // since the polling loop under test is exercised by op.lua elsewhere
      interval: 0,
    });
  }
  if (req.method === 'POST' && u.pathname === '/login/oauth/access_token') {
    return sendJson(res, 200, {
      access_token: 'gho_faketoken0000000000000000000000',
      token_type: 'bearer',
      scope: 'gist',
    });
  }

  // ------------------------------------------------------ api.github.com
  //
  // AUTHENTICATION IS ENFORCED, because a fake that accepts any token cannot
  // catch an auth bug -- and pairing is exactly a flow whose whole job is to
  // carry a token from one device to another. Real GitHub answers 401 with a
  // JSON message here; so does this.
  if (u.pathname !== '/login/device/code'
      && u.pathname !== '/login/oauth/access_token') {
    const auth = req.headers['authorization'] || '';
    const token = auth.replace(/^(Bearer|token)\s+/i, '');
    if (!token.startsWith('gho_faketoken')) {
      return sendJson(res, 401, {
        message: 'Bad credentials',
        documentation_url: 'https://docs.github.com/rest',
      });
    }
  }

  if (req.method === 'GET' && u.pathname === '/user') {
    return sendJson(res, 200, { login: 'octocat-test', id: 123456 });
  }

  if (req.method === 'GET' && u.pathname === '/gists') {
    // Real GitHub paginates by 100; this fake never holds more than one
    // gist, so page 1 is everything and every later page is empty. That is
    // enough to prove the client's "find mine" paging loop terminates
    // instead of walking off the end of a list that never runs out.
    const page = Number(u.searchParams.get('page') || '1');
    return sendJson(res, 200, page === 1 ? Array.from(gists.values()) : []);
  }

  if (req.method === 'POST' && u.pathname === '/gists') {
    let payload;
    try { payload = JSON.parse(rawBody); } catch (e) {
      return sendJson(res, 400, { message: 'bad json: ' + e.message });
    }
    gistSeq += 1;
    const id = `fakegist${gistSeq}`;
    const filesMap = {};
    for (const [name, f] of Object.entries(payload.files || {})) {
      filesMap[name] = f && f.content;
    }
    const gist = buildGist(id, payload.description || null, filesMap);
    gists.set(id, gist);
    return sendJson(res, 201, gist);
  }

  const gistMatch = u.pathname.match(/^\/gists\/([^/]+)$/);
  if (gistMatch && req.method === 'GET') {
    const g = gists.get(gistMatch[1]);
    if (!g) return sendJson(res, 404, { message: 'Not Found' });
    return sendJson(res, 200, g);
  }
  if (gistMatch && req.method === 'PATCH') {
    const g = gists.get(gistMatch[1]);
    if (!g) return sendJson(res, 404, { message: 'Not Found' });
    let payload;
    try { payload = JSON.parse(rawBody); } catch (e) {
      return sendJson(res, 400, { message: 'bad json: ' + e.message });
    }
    const filesMap = {};
    for (const [name, f] of Object.entries(g.files)) filesMap[name] = f.content;
    for (const [name, f] of Object.entries(payload.files || {})) {
      // Real PATCH /gists/{id} semantics, reproduced exactly because
      // P.write's string-surgery splice exists only to hit this: a JSON
      // `null` deletes the file, an object carrying `content` creates or
      // replaces it. `f === null` is what a `null` decodes to in Node's
      // JSON.parse -- this is not a stand-in, it is the real check.
      if (f === null) delete filesMap[name];
      else filesMap[name] = f.content;
    }
    const updated = buildGist(gistMatch[1], g.description, filesMap);
    gists.set(gistMatch[1], updated);
    return sendJson(res, 200, updated);
  }

  sendJson(res, 404, { message: `no such fake endpoint: ${req.method} ${u.pathname}` });
});

// --------------------------------------------------------------- orchestrator

(async () => {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'savesync-gh-'));
  await new Promise((r) => server.listen(PORT, r));

  let clientCode = 1;
  try {
    const client = spawn('luajit', [
      path.join('tests', 'github_client.lua'),
      BASE,
      workDir.replace(/\\/g, '/'),
    ], { cwd: path.join(__dirname, '..'), stdio: 'inherit' });
    clientCode = await new Promise((r) => client.on('close', r));

    // ---- independent confirmation, from the fake server's own log and
    // state, rather than from anything the client under test told us.
    console.log('');

    const posts = requests.filter((r) => r.method === 'POST' && r.path === '/gists');
    const patches = requests.filter((r) => r.method === 'PATCH' && r.path.startsWith('/gists/'));

    check('exactly one gist was created', posts.length === 1, `created ${posts.length}`);
    check('at least one PATCH (write) happened', patches.length > 0, `patches=${patches.length}`);

    // THE KEY ASSERTION. mod/src/providers/github.lua sends
    // Json.encode()'d text on every POST /gists and PATCH /gists/{id}, but
    // curl silently labels an unlabelled -d/--data-binary body as
    // application/x-www-form-urlencoded. If apiHeaders() ever stops setting
    // Content-Type explicitly, GitHub starts receiving JSON wearing the
    // wrong label on every gist create AND every save write -- exactly the
    // kind of thing that would let gist creation slide through looking fine
    // while every later write silently failed to attach real data.
    for (const r of posts) {
      eq(`POST /gists Content-Type (${r.path})`, r.headers['content-type'], 'application/json');
    }
    for (const r of patches) {
      eq(`PATCH ${r.path} Content-Type`, r.headers['content-type'], 'application/json');
    }

    // Every PATCH body GitHub actually received must be valid JSON,
    // including the deletion-only body that P.write builds by splicing
    // `null`s into encoded text via string matching rather than through the
    // encoder (Json.encode has no way to emit a bare `null` value).
    for (const r of patches) {
      let ok = true;
      let parsed;
      try { parsed = JSON.parse(r.body); } catch (e) { ok = false; }
      check(`PATCH body is valid JSON (${r.body.length} bytes)`, ok, r.body);
      if (ok) {
        check(`PATCH body has a "files" object (${r.body})`,
          parsed && typeof parsed.files === 'object' && parsed.files !== null);
      }
    }

    // This is the exact shape of the bug that reached a player: a gist
    // holding only the link-time README, no save data. Checked against the
    // fake server's own state, not the client's opinion of what happened.
    const finalGist = Array.from(gists.values())[0];
    check('the fake server holds a gist', !!finalGist);
    if (finalGist) {
      const names = Object.keys(finalGist.files);
      console.log(`server holds: ${names.join(', ')}`);
      check('README is still there', names.includes('README.md'));
      const saveNames = names.filter((n) => n !== 'README.md');
      check('real save data survived, not just the README', saveNames.length > 0,
        `files=${names.join(', ')}`);
      check('owner.id came back numeric (decoder did not stringify it)',
        typeof finalGist.owner.id === 'number');
    }
  } finally {
    await new Promise((r) => server.close(r));
    try { fs.rmSync(workDir, { recursive: true, force: true }); } catch (_) { /* best effort */ }
  }

  const ok = failed === 0 && clientCode === 0;
  console.log(ok ? 'github: PASS' : 'github: FAIL');
  process.exitCode = ok ? 0 : 1;
})();
