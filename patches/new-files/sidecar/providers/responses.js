/* sidecar/providers/responses.js — a GENERIC OpenAI Responses-protocol adapter
   (POST {baseUrl}/responses, non-streaming) for endpoints that do not speak
   chat/completions at all (e.g. the OpenCode Go gateway, whose thinking models
   answer only on /v1/responses and 400 chat/completions with ModelProtocolUnsupported).

   Implements the LLMProvider seam (provider.js): stream(req) -> AsyncIterable<HarnessEvent>,
   plus listModels / contextLimit / priceOf / supportsTools / reasoningEfforts.
   `fetch` is INJECTED (Node global in the host, a fake in tests).

   REQUEST: the loop's chat-style `messages` are converted to Responses `input[]` items —
   the leading system message is lifted into `instructions`, user/assistant turns become
   typed-content messages (input_text / output_text), assistant tool calls become
   `function_call` items, tool results become `function_call_output` items, and parked
   reasoning blocks ride back as verbatim `reasoning` input items ahead of the turn that
   produced them. Tools use the Responses function-tool schema. Malformed tool pairs are
   repaired exactly like the codex adapter's wire rule so one bad turn can never brick
   the chat permanently.

   RESPONSE: non-streaming — the whole response object arrives at once. Output items are
   normalized back to the SAME HarnessEvent stream the proven loop consumes (text deltas,
   tool_start/args/done, reasoning blocks, usage, exactly one done).

   TIMEOUTS: endpoints behind buffering proxies answer only when the whole turn is done,
   so time-to-first-byte IS the turn time (thinking models routinely take 60s+). The
   shared 30s connect ceiling would abort healthy turns, so each attempt runs under
   STARNET_RESPONSES_CONNECT_MS / SKYNET_RESPONSES_CONNECT_MS (default 300000ms).

   TOKEN BUDGET: thinking consumes max_output_tokens before any text is emitted. The
   loop's small casual-turn caps would return empty output on a thinking model, so an
   explicit cap is floored at MIN_OUTPUT_TOKENS (1024); the default cap is 8192. */
'use strict';
(function (root, factory) {
  if (typeof module !== 'undefined' && module.exports) module.exports = factory(require('./provider.js'), require('./errorClass.js'), require('./toolschema.js'));
  else { root.SK = root.SK || {}; root.SK.providers = root.SK.providers || {}; root.SK.providers.responses = factory(root.SK.providers.provider, root.SK.providers.errorClass, root.SK.providers.toolschema); }
})(typeof globalThis !== 'undefined' ? globalThis : this, function (provider, errorClass, toolschema) {
  'use strict';

  const normalizeFinish = provider.normalizeFinish;
  const classifyApiError = errorClass.classifyApiError;
  const timeouts = provider.timeouts;
  const isAbort = provider.runtime.isAbort;
  const delay = provider.runtime.abortableDelay;

  const RETRY_DELAYS = [500, 1500];
  const DEFAULT_MAX_OUTPUT_TOKENS = 8192;
  const MIN_OUTPUT_TOKENS = 1024;
  const CONNECT_MS_DEFAULT = 300000;
  const EFFORTS = ['none', 'low', 'medium', 'high'];

  function envInt(names, dflt) {
    try {
      for (const name of names) {
        const v = (typeof process !== 'undefined' && process.env) ? process.env[name] : undefined;
        if (v == null || String(v).trim() === '') continue;
        const n = parseInt(v, 10);
        if (isFinite(n) && n > 0) return n;
      }
    } catch (_) {}
    return dflt;
  }
  function connectMs() { return envInt(['STARNET_RESPONSES_CONNECT_MS', 'SKYNET_RESPONSES_CONNECT_MS'], CONNECT_MS_DEFAULT); }

  function textPart(role, text) { return { type: role === 'assistant' ? 'output_text' : 'input_text', text: String(text == null ? '' : text) }; }

  function contentToParts(content, role) {
    if (content == null) return [];
    if (typeof content === 'string') return content ? [textPart(role, content)] : [];
    if (Array.isArray(content)) {
      const out = [];
      for (const p of content) {
        if (typeof p === 'string') { if (p) out.push(textPart(role, p)); continue; }
        if (!p || typeof p !== 'object') continue;
        if (p.type === 'text' || p.type === 'input_text' || p.type === 'output_text') { out.push(textPart(role, p.text || '')); continue; }
        if (p.type === 'image_url' || p.type === 'input_image') {
          const url = (p.image_url && (p.image_url.url || p.image_url)) || p.url || '';
          if (url) out.push({ type: 'input_image', image_url: url });
        }
      }
      return out;
    }
    return [textPart(role, String(content))];
  }

  function extractInstructions(messages) {
    let instructions = '';
    let rest = messages || [];
    if (rest.length && rest[0] && rest[0].role === 'system') {
      instructions = String(rest[0].content == null ? '' : rest[0].content).trim();
      rest = rest.slice(1);
    }
    return { instructions, rest };
  }

  function parkedReasoningItems(msg) {
    const out = [];
    const blocks = msg && Array.isArray(msg.reasoning) ? msg.reasoning : [];
    for (const b of blocks) {
      if (b && b.type === 'responses_reasoning' && b.item && typeof b.item === 'object') out.push(b.item);
    }
    return out;
  }

  function messagesToInput(messages) {
    const input = [];
    const open = new Map();
    const answered = new Set();
    let minted = 0;
    for (const msg of (messages || [])) {
      if (!msg || typeof msg !== 'object') continue;
      const role = msg.role;
      if (role === 'system') { input.push({ role: 'user', content: contentToParts(msg.content, 'user') }); continue; }
      if (role === 'tool') {
        const callId = String(msg.tool_call_id || msg.call_id || '');
        const body = String(msg.content == null ? '' : msg.content);
        if (callId && open.has(callId)) {
          input.push({ type: 'function_call_output', call_id: callId, output: body });
          open.delete(callId); answered.add(callId);
        } else {
          input.push({ role: 'user', content: [textPart('user', '[recovered tool result' + (callId ? ' ' + callId : '') + ' -- its originating call is not in this transcript]\n' + body)] });
        }
        continue;
      }
      if (role === 'assistant') {
        for (const item of parkedReasoningItems(msg)) input.push(item);
        const parts = contentToParts(msg.content, 'assistant');
        if (parts.length) input.push({ role: 'assistant', content: parts });
        if (Array.isArray(msg.tool_calls)) {
          for (const tc of msg.tool_calls) {
            const fn = (tc && tc.function) || {};
            const callId = String(tc.id || fn.call_id || '') || ('call_local_' + (++minted));
            input.push({
              type: 'function_call',
              call_id: callId,
              name: fn.name || '',
              arguments: typeof fn.arguments === 'string' ? fn.arguments : JSON.stringify(fn.arguments || {})
            });
            if (!answered.has(callId)) open.set(callId, input.length - 1);
          }
        }
        continue;
      }
      input.push({ role: 'user', content: contentToParts(msg.content, 'user') });
    }
    const unpaired = Array.from(open.entries()).sort((a, b) => b[1] - a[1]);
    for (const [callId, pos] of unpaired) {
      input.splice(pos + 1, 0, { type: 'function_call_output', call_id: callId, output: '[interrupted -- this call produced no recorded result. Reissue it if it is still needed.]' });
    }
    return input;
  }

  function toResponsesTools(tools) {
    if (!tools || !tools.length) return null;
    const out = [];
    for (const item of tools) {
      const fn = (item && item.function) || {};
      const name = fn.name;
      if (typeof name !== 'string' || !name.trim()) continue;
      out.push({ type: 'function', name: name, description: fn.description || '', parameters: toolschema.sanitizeKeys(fn.parameters) || { type: 'object', properties: {} } });
    }
    return out.length ? out : null;
  }

  function normalizeResponsesEffort(value, dflt) {
    const key = String(value == null || value === '' ? (dflt || 'medium') : value).trim().toLowerCase().replace(/[\s_-]+/g, '');
    if (key === 'none' || key === 'off' || key === 'no' || key === 'disabled') return '';
    if (key === 'minimal' || key === 'min' || key === 'low') return 'low';
    if (key === 'medium' || key === 'med' || key === 'mid') return 'medium';
    if (key === 'high' || key === 'xhigh' || key === 'max' || key === 'extrahigh') return 'high';
    return 'medium';
  }

  function normalizeUsage(u) {
    u = u || {};
    const out = {
      prompt_tokens: Number(u.prompt_tokens) || 0,
      completion_tokens: Number(u.completion_tokens) || 0,
      total_tokens: Number(u.total_tokens) || 0
    };
    if (u.prompt_tokens_details != null) out.prompt_tokens_details = u.prompt_tokens_details;
    if (u.completion_tokens_details != null) out.completion_tokens_details = u.completion_tokens_details;
    if (u.cost != null) out.cost = u.cost;
    return out;
  }

  function safeErrorField(value, limit) {
    if (value == null || (typeof value === 'object' && typeof value !== 'number')) return '';
    return String(value)
      .replace(/\bBearer\s+\S+/gi, 'Bearer [redacted]')
      .replace(/[\r\n\t\0-\x08\x0b\x0c\x0e-\x1f\x7f]+/g, ' ')
      .replace(/\s+/g, ' ').trim().slice(0, limit || 300);
  }

  function makeResponsesProvider(opts) {
    opts = opts || {};
    const doFetch = opts.fetch || (typeof fetch !== 'undefined' ? fetch : null);
    if (!doFetch) throw new Error('responses provider requires fetch (Node 18+) or opts.fetch');
    const key = String(opts.key || '');
    const baseUrl = String(opts.baseUrl || '').replace(/\/+$/, '');
    if (!baseUrl) throw new Error('responses provider has no endpoint configured (base URL missing)');
    const responsesPath = String(opts.responsesPath || '/responses');
    const modelsPath = String(opts.modelsPath || '/models');
    const defaultEffort = normalizeResponsesEffort(opts.reasoningEffort || 'medium', 'medium') || 'medium';
    const maxOut = Math.floor(Number(opts.maxOutputTokens) || 0) > 0 ? Math.floor(Number(opts.maxOutputTokens)) : DEFAULT_MAX_OUTPUT_TOKENS;

    function buildBody(req) {
      const prepared = provider.prepareWireMessages(req.messages || [], 'responses');
      const found = extractInstructions(prepared);
      const effort = normalizeResponsesEffort(req.reasoningEffort || defaultEffort, defaultEffort);
      const explicit = Math.floor(Number(req.max_tokens || req.maxTokens || 0)) || 0;
      const cap = explicit > 0 ? Math.max(explicit, MIN_OUTPUT_TOKENS) : maxOut;
      const body = { model: req.model, stream: false, max_output_tokens: cap, input: messagesToInput(found.rest) };
      if (found.instructions) body.instructions = found.instructions;
      if (effort) body.reasoning = { effort };
      const tools = toResponsesTools(req.tools);
      if (tools) { body.tools = tools; body.tool_choice = 'auto'; }
      return body;
    }

    function stream(req) { return toolschema.withRestoredArgKeys(runStream(req), req && req.tools); }

    async function* runStream(req) {
      req = req || {};
      if (req.signal && req.signal.aborted) return;
      const body = buildBody(req);
      const maxRetries = provider.runtime.preStreamRetries(req, RETRY_DELAYS.length);
      let res = null, waited = 0;
      for (let attempt = 0; ; attempt++) {
        if (req.signal && req.signal.aborted) return;
        const guard = timeouts.connectGuard(req.signal, connectMs());
        try {
          res = await doFetch(baseUrl + responsesPath, {
            method: 'POST',
            headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json', 'Accept': 'application/json' },
            body: JSON.stringify(body),
            signal: guard.signal
          });
        } catch (e) {
          if (isAbort(e, req.signal)) return;
          if (!classifyApiError(e, { model: body.model }).retryable) throw e;
          if (attempt < maxRetries) { waited += RETRY_DELAYS[attempt]; await delay(RETRY_DELAYS[attempt], req.signal); continue; }
          throw provider.runtime.markPreStreamRetriesExhausted(e, { attempts: attempt + 1, waitedMs: waited });
        } finally {
          guard.disarm();
        }
        if (res.ok) break;
        let detail = '', errBody = null;
        try { const j = await res.json(); errBody = j; detail = (j && j.error && (j.error.message || j.error.code || j.error.type)) || JSON.stringify(j); }
        catch (_) { try { detail = (await res.text()).slice(0, 300); } catch (__) {} }
        const err = new Error('responses http ' + res.status + ' -- ' + safeErrorField(detail, 500));
        err.status = res.status;
        err.headers = res.headers;
        if (errBody && typeof errBody === 'object') { err.body = errBody; err.ownMessage = true; }
        const cls = classifyApiError(err, { model: body.model });
        err.transient = cls.retryable;
        if (cls.retryable && attempt < maxRetries) {
          const wait = Math.min(60000, Math.max(RETRY_DELAYS[attempt], cls.retryAfterMs || 0));
          waited += wait; await delay(wait, req.signal); continue;
        }
        throw cls.retryable ? provider.runtime.markPreStreamRetriesExhausted(err, { attempts: attempt + 1, waitedMs: waited }) : err;
      }
      let r;
      try { r = await res.json(); }
      catch (e) { throw new Error('responses: unreadable JSON response body'); }
      if (!r || typeof r !== 'object') throw new Error('responses: empty response object');

      let sawToolCall = false, toolIndex = 0;
      for (const item of (Array.isArray(r.output) ? r.output : [])) {
        if (!item || typeof item !== 'object') continue;
        if (item.type === 'reasoning') {
          yield { type: 'reasoning', block: { type: 'responses_reasoning', item } };
          continue;
        }
        if (item.type === 'message') {
          const parts = Array.isArray(item.content) ? item.content : [];
          for (const p of parts) {
            if (p && (p.type === 'output_text' || p.type === 'text') && typeof p.text === 'string' && p.text) {
              yield { type: 'text', delta: p.text };
            }
          }
          continue;
        }
        if (item.type === 'function_call') {
          sawToolCall = true;
          const idx = toolIndex++;
          const id = String(item.call_id || item.id || '') || ('call_' + idx);
          yield { type: 'tool_start', index: idx, id, name: String(item.name || '') };
          const args = typeof item.arguments === 'string' ? item.arguments : JSON.stringify(item.arguments == null ? {} : item.arguments);
          if (args) yield { type: 'tool_args', index: idx, chunk: args };
          yield { type: 'tool_done', index: idx };
          continue;
        }
      }
      if (r.usage) yield { type: 'usage', usage: normalizeUsage(r.usage) };
      if (r.status === 'failed') {
        const fe = (r.error && (r.error.message || r.error.code)) || 'response failed';
        const err = new Error('responses failed: ' + safeErrorField(fe, 300));
        err.body = { error: r.error || {} }; err.ownMessage = true;
        throw err;
      }
      let finish = sawToolCall ? 'tool_calls' : 'stop';
      if (r.status === 'incomplete') {
        const why = String((r.incomplete_details && r.incomplete_details.reason) || '');
        finish = /max_output_tokens|length/.test(why) ? 'length' : 'stop';
      }
      yield { type: 'done', finishReason: normalizeFinish(finish), truncated: false };
    }

    async function listModels() {
      try {
        const res = await doFetch(baseUrl + modelsPath, { headers: { 'Authorization': 'Bearer ' + key, 'Accept': 'application/json' } });
        if (!res.ok) return [];
        const j = await res.json();
        const list = (j && j.data) || [];
        if (!Array.isArray(list)) return [];
        return list.map(m => ({
          id: String((m && m.id) || ''),
          name: String((m && (m.name || m.id)) || ''),
          context_length: Number((m && m.context_length) || 0) || 0,
          max_completion_tokens: null,
          pricing: (m && m.pricing) || null,
          supported_parameters: [],
          supportsTools: null,
          supportsReasoning: null,
          reasoningEfforts: []
        })).filter(m => m.id);
      } catch (_) { return []; }
    }
    function contextLimit() { return 0; }
    function priceOf() { return null; }
    function supportsTools() { return null; }
    function reasoningEfforts() { return EFFORTS.slice(); }

    return { stream, listModels, contextLimit, priceOf, supportsTools, reasoningEfforts };
  }

  return { makeResponsesProvider, _internals: { messagesToInput, extractInstructions, toResponsesTools, normalizeResponsesEffort, normalizeUsage, MIN_OUTPUT_TOKENS, DEFAULT_MAX_OUTPUT_TOKENS } };
});