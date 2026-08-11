#!/usr/bin/env node
//
// Gen1Recomp SaveSync -- self-hosted backend.
//
// Node standard library only: no npm install, no lockfile, no supply chain.
// The whole protocol is four endpoints over a folder of small files, which is
// the point -- if this repository disappears, anyone can reimplement it in an
// afternoon in whatever language they like.
//
//   GET  /v1/hello        -> { ok: true, name }
//   GET  /v1/files        -> { files: { "<name>": <size> } }
//   GET  /v1/file/<name>  -> the raw bytes (404 if absent)
//   POST /v1/batch        -> { files: { "<name>": "<content>" | null } }
//
// Every request carries `Authorization: Bearer <token>`.  A token names one
// storage folder: two devices holding the same token see the same saves, and
// that is all "pair another device" has ever needed to mean.  On first boot
// the server mints a token, prints the setup code, and writes it to
// /data/setup-code.txt -- paste that into the game and you are done.

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '8787', 10);
const DATA_DIR = process.env.DATA_DIR || '/data';
const PUBLIC_URL = (process.env.PUBLIC_URL || `http://localhost:${PORT}`)
  .replace(/\/+$/, '');
const SERVER_NAME = process.env.SERVER_NAME || 'My save server';

// A Gen 1 save is about 32 KB.  These ceilings are two orders of magnitude
// above anything legitimate, and they are what stops the endpoint from being
// a free file host if a token ever leaks.
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_FILES_PER_TOKEN = 500;
const MAX_BODY_BYTES = 8 * 1024 * 1024;

// -------------------------------------------------------------- storage

fs.mkdirSync(DATA_DIR, { recursive: true });

const TOKENS_FILE = path.join(DATA_DIR, 'tokens.json');

function loadTokens() {
  // Explicit tokens win: an operator who sets SAVESYNC_TOKENS is managing
  // them somewhere else (a compose file, a secrets store) and the server
  // should not quietly mint extras alongside.
  const fromEnv = (process.env.SAVESYNC_TOKENS || '')
    .split(',').map((s) => s.trim()).filter(Boolean);
  if (fromEnv.length) return fromEnv;

  if (fs.existsSync(TOKENS_FILE)) {
    try {
      const list = JSON.parse(fs.readFileSync(TOKENS_FILE, 'utf8'));
      if (Array.isArray(list) && list.length) return list;
    } catch (_) { /* fall through and mint a fresh one */ }
  }
  const token = crypto.randomBytes(24).toString('base64url');
  fs.writeFileSync(TOKENS_FILE, JSON.stringify([token], null, 2));
  return [token];
}

const TOKENS = new Set(loadTokens());

// The token is the credential, so it must not also be a path component that
// could end up in a log or a directory listing.
function storageDir(token) {
  const id = crypto.createHash('sha256').update(token).digest('hex').slice(0, 24);
  const dir = path.join(DATA_DIR, 'stores', id);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// Names are flat by protocol: "<key>.sav", "<key>.json", "<key>.h0003.sav".
// Anything else -- a slash, a dot-dot, a control character -- is rejected
// rather than sanitised, because a sanitised name is a name the client did
// not ask for and would then fail to read back.
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
function validName(name) {
  return typeof name === 'string' && NAME_RE.test(name) && !name.includes('..');
}

function writeAtomic(dir, name, content) {
  const tmp = path.join(dir, `.${name}.tmp`);
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, path.join(dir, name));
}

// ------------------------------------------------------------ plumbing

function send(res, code, obj, headers) {
  const body = typeof obj === 'string' || Buffer.isBuffer(obj)
    ? obj : JSON.stringify(obj);
  res.writeHead(code, Object.assign({
    'Content-Type': typeof obj === 'object' && !Buffer.isBuffer(obj)
      ? 'application/json' : 'application/octet-stream',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  }, headers || {}));
  res.end(body);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function tokenOf(req) {
  const h = req.headers.authorization || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const given = m[1].trim();
  // Constant-time compare against each known token: this endpoint is public
  // and a timing oracle on a bearer token is a real (if slow) attack.
  for (const known of TOKENS) {
    const a = Buffer.from(given);
    const b = Buffer.from(known);
    if (a.length === b.length && crypto.timingSafeEqual(a, b)) return known;
  }
  return null;
}

// ------------------------------------------------------------- routes

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const route = url.pathname;

  if (route === '/' || route === '/health') {
    return send(res, 200, { ok: true, service: 'gen1recomp-savesync' });
  }
  if (!route.startsWith('/v1/')) return send(res, 404, { error: 'not found' });

  const token = tokenOf(req);
  if (!token) return send(res, 401, { error: 'bad or missing token' });
  const dir = storageDir(token);

  try {
    if (route === '/v1/hello' && req.method === 'GET') {
      return send(res, 200, { ok: true, name: SERVER_NAME });
    }

    if (route === '/v1/files' && req.method === 'GET') {
      const files = {};
      for (const name of fs.readdirSync(dir)) {
        if (name.startsWith('.')) continue;
        files[name] = fs.statSync(path.join(dir, name)).size;
      }
      return send(res, 200, { files });
    }

    if (route.startsWith('/v1/file/') && req.method === 'GET') {
      const name = decodeURIComponent(route.slice('/v1/file/'.length));
      if (!validName(name)) return send(res, 400, { error: 'bad name' });
      const p = path.join(dir, name);
      if (!fs.existsSync(p)) return send(res, 404, { error: 'not found' });
      return send(res, 200, fs.readFileSync(p));
    }

    if (route === '/v1/batch' && req.method === 'POST') {
      const raw = await readBody(req, MAX_BODY_BYTES);
      let payload;
      try {
        // fatal:true, NOT raw.toString('utf8'). The lenient decoder replaces
        // every invalid byte with U+FFFD, so a save that is not valid UTF-8
        // would be accepted and stored CORRUPTED, with no error anywhere --
        // the worst possible outcome for a backup service. Clients send
        // payloads base64-wrapped precisely so this can never fire; if it
        // does, something upstream is broken and silence would hide it.
        payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
      } catch (_) {
        return send(res, 400, { error: 'bad json' });
      }
      const files = payload && payload.files;
      if (!files || typeof files !== 'object') {
        return send(res, 400, { error: 'no files' });
      }

      // Validate the WHOLE batch before writing any of it, so a bad name in
      // the middle cannot leave the store half-updated -- the client's
      // conflict rules assume a batch either landed or did not.
      const writes = [];
      const deletes = [];
      for (const [name, content] of Object.entries(files)) {
        if (!validName(name)) return send(res, 400, { error: `bad name: ${name}` });
        if (content === null) {
          deletes.push(name);
        } else if (typeof content === 'string') {
          if (Buffer.byteLength(content) > MAX_FILE_BYTES) {
            return send(res, 413, { error: `too big: ${name}` });
          }
          writes.push([name, content]);
        } else {
          return send(res, 400, { error: `bad content: ${name}` });
        }
      }
      const existing = fs.readdirSync(dir).filter((n) => !n.startsWith('.'));
      const after = new Set(existing);
      for (const n of deletes) after.delete(n);
      for (const [n] of writes) after.add(n);
      if (after.size > MAX_FILES_PER_TOKEN) {
        return send(res, 507, { error: 'too many files' });
      }

      for (const [name, content] of writes) writeAtomic(dir, name, content);
      for (const name of deletes) {
        try { fs.unlinkSync(path.join(dir, name)); } catch (_) { /* already gone */ }
      }
      return send(res, 200, { ok: true, wrote: writes.length, deleted: deletes.length });
    }

    return send(res, 404, { error: 'not found' });
  } catch (err) {
    return send(res, 500, { error: String(err && err.message || err) });
  }
});

// ---------------------------------------------------------------- boot

function setupCode(token) {
  const payload = JSON.stringify({ provider: 'server', url: PUBLIC_URL, token,
    account: SERVER_NAME });
  return 'SSYNC1.' + Buffer.from(payload, 'utf8').toString('base64url');
}

server.listen(PORT, () => {
  const first = TOKENS.values().next().value;
  const code = setupCode(first);
  try {
    fs.writeFileSync(path.join(DATA_DIR, 'setup-code.txt'), code + '\n');
  } catch (_) { /* read-only /data is the operator's problem, not fatal */ }
  console.log(`gen1recomp SaveSync listening on :${PORT}`);
  console.log(`public url: ${PUBLIC_URL}`);
  console.log('');
  console.log('Paste this into the game (SaveSync -> Set Up -> Use a setup code):');
  console.log('');
  console.log('  ' + code);
  console.log('');
  console.log('It is also saved to /data/setup-code.txt. Treat it like a password.');
});
