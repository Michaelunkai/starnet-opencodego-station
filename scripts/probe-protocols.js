'use strict';
// probe-protocols.js — for each credential, test mimo-v2.5 across the three OpenCode Go
// protocols to find which one the account actually serves. Read-only diagnostic; never prints keys.
const fs = require('node:fs');

// Path to a newline-separated file of OpenCode Go API keys. Override with OPENCODE_GO_CRED_FILE.
const CRED = process.env.OPENCODE_GO_CRED_FILE || 'opencode-go-keys.txt';
const BASE = 'https://opencode.ai/zen/go/v1';
const MODEL = process.argv[2] || 'mimo-v2.5';
const PROTOCOLS = [
  { name: 'chat/completions', path: '/chat/completions', body: () => ({ model: MODEL, messages: [{ role: 'user', content: 'Reply with exactly: OK' }], max_tokens: 32, stream: false }) },
  { name: 'responses', path: '/responses', body: () => ({ model: MODEL, input: 'Reply with exactly: OK', max_output_tokens: 32 }) },
  { name: 'messages', path: '/messages', body: () => ({ model: MODEL, max_tokens: 32, messages: [{ role: 'user', content: 'Reply with exactly: OK' }] }) }
];

function mask(k) { const s = String(k || ''); return s.slice(0, 12) + '...' + s.slice(-4); }

(async () => {
  const keys = fs.readFileSync(CRED, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  console.log('model under test: ' + MODEL + '  |  keys: ' + keys.length);
  for (let i = 0; i < keys.length; i++) {
    for (const p of PROTOCOLS) {
      const label = 'key ' + (i + 1) + ' [' + mask(keys[i]) + '] ' + p.name.padEnd(16);
      try {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 90000);
        const res = await fetch(BASE + p.path, {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + keys[i], 'Content-Type': 'application/json',
            'Accept': 'application/json', 'x-opencode-session': 'probe-' + i + '-' + Date.now()
          },
          body: JSON.stringify(p.body()),
          signal: ctrl.signal
        });
        clearTimeout(timer);
        const text = await res.text();
        let detail = '';
        try { const j = JSON.parse(text); detail = (j && j.error && (j.error.message || j.error.type)) || (j && j.status) || ''; }
        catch (_) { detail = text.slice(0, 140); }
        console.log(label + ' -> HTTP ' + res.status + (res.ok ? '  OK' : '  FAIL') + (detail ? '  (' + String(detail).slice(0, 160) + ')' : ''));
      } catch (e) {
        console.log(label + ' -> transport: ' + (e && e.message));
      }
    }
  }
})();
