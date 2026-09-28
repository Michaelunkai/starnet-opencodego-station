'use strict';
// probe-keys.js — test each OpenCode Go credential against the live upstream and report
// status per key WITHOUT printing any key material. Read-only diagnostic.
const fs = require('node:fs');
const path = require('node:path');

// Path to a newline-separated file of OpenCode Go API keys. Override with OPENCODE_GO_CRED_FILE.
const CRED = process.env.OPENCODE_GO_CRED_FILE || 'opencode-go-keys.txt';
const UPSTREAM = 'https://opencode.ai/zen/go/v1/responses';
const MODEL = process.argv[2] || 'mimo-v2.5';

function mask(k) {
  const s = String(k || '');
  return s.slice(0, 12) + '...' + s.slice(-4);
}

(async () => {
  const raw = fs.readFileSync(CRED, 'utf8');
  const keys = raw.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  console.log('credential file: ' + CRED);
  console.log('keys found: ' + keys.length);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    const label = 'key ' + (i + 1) + ' [' + mask(k) + ']';
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 90000);
      const res = await fetch(UPSTREAM, {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + k, 'Content-Type': 'application/json', 'Accept': 'application/json', 'x-opencode-session': 'probe-' + i + '-' + Date.now() },
        body: JSON.stringify({ model: MODEL, input: 'Reply with exactly: OK', max_output_tokens: 32 }),
        signal: ctrl.signal
      });
      clearTimeout(timer);
      const text = await res.text();
      let detail = '';
      try { const j = JSON.parse(text); detail = (j && j.error && (j.error.message || j.error.type)) || (j && j.status) || ''; }
      catch (_) { detail = text.slice(0, 160); }
      console.log(label + ' -> HTTP ' + res.status + (res.ok ? ' OK' : ' FAIL') + (detail ? '  (' + String(detail).slice(0, 200) + ')' : ''));
    } catch (e) {
      console.log(label + ' -> transport error: ' + (e && e.message));
    }
  }
})();
