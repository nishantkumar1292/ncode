'use strict';
/* ncode renderer: owns the Claude Code stream-json protocol for every open session. */

// ---------------------------------------------------------------- utils
const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => MD.esc(s ?? '');
function h(tag, attrs, ...kids) {
  const [t, ...cls] = tag.split('.');
  const el = document.createElement(t || 'div');
  if (cls.length) el.className = cls.join(' ');
  if (attrs) for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'html') el.innerHTML = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) el.append(k.nodeType ? k : document.createTextNode(String(k)));
  return el;
}
const native = (op, payload = {}) => {
  try {
    return Promise.resolve(window.webkit.messageHandlers.bridge.postMessage({ op, ...payload }))
      .catch((err) => { console.warn('bridge', op, err); return null; });
  } catch (e) { console.warn('bridge unavailable', op); return Promise.resolve(null); }
};
const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
const fmtTok = (n) => n == null ? '' : n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1000 ? (n / 1000).toFixed(n >= 1e4 ? 0 : 1) + 'k' : String(n);
const fmtDur = (ms) => { if (ms == null) return ''; const s = Math.round(ms / 1000); return s < 60 ? s + 's' : Math.floor(s / 60) + 'm ' + (s % 60) + 's'; };
const store = { get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } }, set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} } };
function toast(text, ms = 3200) { const t = h('div.toast', { text }); $('#toasts').append(t); setTimeout(() => t.remove(), ms); }
function textOf(content) {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.filter((b) => b && b.type === 'text').map((b) => b.text).join('\n');
  return JSON.stringify(content, null, 2);
}
function imagesOf(content) {
  if (!Array.isArray(content)) return [];
  return content.filter((b) => b && b.type === 'image' && b.source).map((b) => b.source.type === 'base64' ? `data:${b.source.media_type};base64,${b.source.data}` : b.source.url);
}
function stripReminders(s) { return (s || '').replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim(); }
function lightbox(src) { const lb = h('div.lightbox', { onclick: () => lb.remove() }, h('img', { src })); document.body.append(lb); }

const MODES = [
  { id: 'default', label: 'Ask permissions', desc: 'Ask before edits and commands' },
  { id: 'acceptEdits', label: 'Accept edits', desc: 'Auto-approve file edits' },
  { id: 'plan', label: 'Plan mode', desc: 'Read-only research, then propose a plan' },
  { id: 'auto', label: 'Auto', desc: 'A classifier approves safe actions' },
  { id: 'bypassPermissions', label: 'Bypass permissions', desc: 'Never ask. Use with care' },
];
const CYCLE = ['default', 'acceptEdits', 'plan', 'auto'];
const APP_COMMANDS = [
  { name: 'clear', description: 'Start a new chat in this project', app: true },
  { name: 'terminal', description: 'Open this session in Terminal (full TUI)', app: true },
  { name: 'activity', description: 'Toggle the activity panel', app: true },
];

// ---------------------------------------------------------------- session state
const sessions = new Map();
let current = null;
let config = { home: '' };
let lastModels = store.get('models', null);

class Session {
  constructor(k) {
    this.k = k;
    this.cwd = '';
    this.title = '';
    this.live = false;
    this.busy = false;
    this.resumable = false;
    this.init = null;            // initialize response
    this.sys = null;             // system/init message
    this.model = null;
    this.mode = store.get('defaultMode', 'default');
    this.opts = {};              // launch options for the first start
    this.cur = {};               // per-parent streaming message: { id, blocks[] }
    this.msgBlocks = new Map();  // message id → block records
    this.tools = new Map();      // tool_use_id → tool record
    this.agents = new Map();     // Agent tool_use_id → agent record
    this.tasks = new Map();      // task_id → task record
    this.bgTasks = [];
    this.pending = new Map();    // control request id → { req, el }
    this.waiters = new Map();    // our request id → resolve
    this.sentQueue = [];         // optimistic user bubbles awaiting replay
    this.draft = { text: '', atts: [], shell: false };
    this.prompts = store.get('hist:' + k, []);
    this.histIdx = -1;
    this.stick = true;
    this.ctx = null;             // context usage response
    this.cost = 0;
    this.usageText = '';
    this.suggestion = '';
    this.turnStart = 0;
    this.verb = 'Thinking';
    this.thinkTok = 0;
    this.outTok = 0;
    this.hasContent = false;

    this.el = h('div.session', { hidden: true });
    this.thread = h('div.thread');
    this.hello = h('div.session-hello');
    this.working = h('div.working', { hidden: true }, h('span.star', { text: '✻' }), h('span.verb', { text: 'Thinking…' }), h('span.meta'));
    this.thread.append(this.hello, this.working);
    this.el.append(this.thread);
    this.el.addEventListener('scroll', () => {
      const near = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 60;
      this.stick = near;
      if (this === current) $('#jump').hidden = near;
    }, { passive: true });
    $('#threads').append(this.el);
  }

  setHello() {
    if (this.hasContent) { this.hello.remove(); return; }
    const name = (this.cwd || '').split('/').filter(Boolean).pop() || 'this project';
    this.hello.replaceChildren(h('h2', { text: greeting() }), h('p', { text: `Working in ${name} · ${this.cwd.replace(config.home, '~')}` }));
  }

  append(el, parent) {
    if (!this.hasContent) { this.hasContent = true; this.hello.remove(); }
    if (parent) {
      const a = ensureAgent(this, parent);
      a.children.append(el);
      return;
    }
    this.thread.insertBefore(el, this.working);
  }

  scroll(force) {
    if (this !== current) return;
    if (force || this.stick) this.el.scrollTop = this.el.scrollHeight;
  }

  // -- protocol output
  write(obj, opts) {
    const line = JSON.stringify(obj);
    return native('write', { k: this.k, line, opts: opts || (this.live ? undefined : this.launchOpts()) });
  }
  launchOpts() { return { model: this.opts.model || '', permissionMode: this.mode, effort: this.opts.effort || '' }; }
  request(sub, extra = {}) {
    if (!this.live) return Promise.resolve(null);
    const id = 'ui-' + uid();
    const p = new Promise((res) => { this.waiters.set(id, res); setTimeout(() => { if (this.waiters.has(id)) { this.waiters.delete(id); res(null); } }, 20000); });
    this.write({ type: 'control_request', request_id: id, request: { subtype: sub, ...extra } });
    return p;
  }
  respond(requestId, response) {
    this.write({ type: 'control_response', response: { subtype: 'success', request_id: requestId, response } });
  }
  respondError(requestId, error) {
    this.write({ type: 'control_response', response: { subtype: 'error', request_id: requestId, error } });
  }
}

function greeting() {
  const hr = new Date().getHours();
  return hr < 5 ? 'Burning the midnight oil?' : hr < 12 ? 'Good morning' : hr < 17 ? 'Good afternoon' : 'Good evening';
}

function getSession(k) {
  let s = sessions.get(k);
  if (!s) { s = new Session(k); sessions.set(k, s); }
  return s;
}

// ---------------------------------------------------------------- inbound from Swift
window.__recv = function (batch) {
  const touched = new Set();
  for (const m of batch) {
    try { route(m, touched); } catch (e) { console.error('route error', e, m); }
  }
  for (const s of touched) { if (s === current) { updateChrome(); s.scroll(); } }
  scheduleActivity();
};

function route(m, touched) {
  switch (m.t) {
    case 'config':
      config = m; window.__home = m.home || '';
      return;
    case 'open': {
      const s = getSession(m.k);
      s.cwd = m.cwd; s.title = m.title; s.resumable = m.resumable;
      if (!m.live && s.live) s.live = false;
      s.setHello();
      return;
    }
    case 'select': return select(m.k);
    case 'drop': { const s = sessions.get(m.k); if (s) { s.el.remove(); sessions.delete(m.k); } return; }
    case 'history': {
      const s = getSession(m.k);
      s.loadingHistory = true;
      for (const line of m.lines) { try { handleEvent(s, line, true); } catch (e) { console.error(e); } }
      s.loadingHistory = false;
      finalizeAllText(s);
      // Anything still "running" in a saved transcript was interrupted or finished off-screen.
      for (const t of s.tools.values()) if (!t.agent && (t.status === 'running' || t.status === 'pending')) { t.status = 'done'; renderTool(t); }
      for (const a of s.agents.values()) if (a.status === 'running') { a.status = 'done'; renderAgent(a); }
      s.setHello();
      touched.add(s);
      if (s === current) requestAnimationFrame(() => s.scroll(true));
      return;
    }
    case 'ev': {
      const s = getSession(m.k);
      handleEvent(s, m.e, false);
      touched.add(s);
      return;
    }
    case 'launch': {
      const s = getSession(m.k);
      if (m.model) s.opts.model = m.model;
      if (m.mode) s.mode = m.mode;
      if (current !== s) select(m.k);
      updateChrome();
      if (m.prompt) { input.value = m.prompt; s.draft.text = m.prompt; submit(); }
      return;
    }
    case 'toast': return toast(m.text);
    case 'cmd': return appCommand(m.name);
    case 'drop-files': return droppedFiles(m.files || []);
  }
}

function select(k) {
  if (current) saveDraft(current);
  for (const s of sessions.values()) s.el.hidden = true;
  current = k ? getSession(k) : null;
  $('#welcome').hidden = !!current;
  $('#composer').hidden = !current;
  if (current) {
    current.el.hidden = false;
    current.setHello();
    loadDraft(current);
    renderDock();
    updateChrome();
    requestAnimationFrame(() => { current.scroll(true); $('#input').focus(); });
  } else {
    $('#dock').replaceChildren();
    $('#status').replaceChildren();
  }
  renderActivity();
}

// ---------------------------------------------------------------- event handling
function handleEvent(S, o, fromHistory) {
  switch (o.type) {
    case 'stream_event': return onStream(S, o);
    case 'assistant': return onAssistant(S, o, fromHistory);
    case 'user': return onUser(S, o, fromHistory);
    case 'system': return onSystem(S, o, fromHistory);
    case 'result': return onResult(S, o);
    case 'control_request': return onControlRequest(S, o);
    case 'control_response': return onControlResponse(S, o);
    case 'control_cancel_request': return removePending(S, o.request_id);
    case 'tool_progress': {
      const t = S.tools.get(o.tool_use_id);
      if (t) { t.elapsed = o.elapsed_time_seconds; updateToolMeta(t); }
      return;
    }
    case 'prompt_suggestion':
      S.suggestion = /^(nothing|no (obvious|clear|further)|none\b|n\/a)/i.test(o.suggestion || '') ? '' : (o.suggestion || '').slice(0, 160);
      if (S === current) updatePlaceholder();
      return;
    case 'rate_limit_event': {
      const info = o.rate_limit_info || {};
      if (info.status && info.status !== 'allowed') S.append(notice(`Rate limit: ${info.status}${info.resetsAt ? ' · resets ' + new Date(info.resetsAt * 1000).toLocaleTimeString() : ''}`, 'error'));
      return;
    }
    case 'auth_status':
      if (o.error) S.append(notice('Authentication: ' + o.error, 'error'));
      return;
    case 'ncode_exit': return onExit(S, o);
  }
}

// ---- streaming
function onStream(S, o) {
  const ev = o.event || {};
  const parent = o.parent_tool_use_id || null;
  const pk = parent || '_';
  switch (ev.type) {
    case 'message_start':
      S.cur[pk] = { id: ev.message?.id, blocks: [] };
      if (!parent) { setBusy(S, true); S.verb = 'Thinking'; }
      return;
    case 'content_block_start': {
      const m = S.cur[pk]; if (!m) return;
      const cb = ev.content_block || {};
      let rec = null;
      if (cb.type === 'text') rec = makeText(S, parent);
      else if (cb.type === 'thinking' || cb.type === 'redacted_thinking') rec = makeThinking(S, parent);
      else if (cb.type === 'tool_use' || cb.type === 'server_tool_use' || cb.type === 'mcp_tool_use') {
        rec = ensureTool(S, cb.id, cb.name, null, parent);
        rec.streaming = true;
        if (!parent) S.verb = verbFor(cb.name);
      }
      if (!rec) return;
      rec.kind = cb.type === 'redacted_thinking' ? 'thinking' : cb.type.endsWith('tool_use') ? 'tool_use' : cb.type;
      m.blocks[ev.index] = rec;
      listFor(S, m.id).push(rec);
      return;
    }
    case 'content_block_delta': {
      const rec = S.cur[pk]?.blocks[ev.index]; if (!rec) return;
      const d = ev.delta || {};
      if (d.type === 'text_delta') { rec.text += d.text; S.outTok += Math.ceil(d.text.length / 4); scheduleText(rec); if (!parent) S.verb = 'Writing'; }
      else if (d.type === 'thinking_delta') { rec.text += d.thinking; scheduleText(rec); }
      else if (d.type === 'input_json_delta') { rec.partial = (rec.partial || '') + (d.partial_json || ''); previewToolInput(rec); }
      return;
    }
    case 'content_block_stop': {
      const rec = S.cur[pk]?.blocks[ev.index]; if (!rec) return;
      if ((rec.kind === 'text' || rec.kind === 'thinking') && !rec.final) renderTextNow(rec, true);
      return;
    }
  }
}

function listFor(S, id) { let l = S.msgBlocks.get(id); if (!l) { l = []; S.msgBlocks.set(id, l); } return l; }

// ---- full assistant messages (live: authoritative copy of streamed blocks; history: only source)
function onAssistant(S, o, fromHistory) {
  const msg = o.message || {};
  const parent = o.parent_tool_use_id || (o.__parent) || null;
  const list = listFor(S, msg.id);
  if (o.error && !fromHistory) S.append(notice(`API error: ${o.error}`, 'error'), parent);
  for (const b of msg.content || []) {
    if (b.type === 'text') {
      let rec = list.find((r) => r.kind === 'text' && !r.final);
      if (!rec) { rec = makeText(S, parent); rec.kind = 'text'; list.push(rec); }
      rec.text = b.text; rec.final = true;
      if (msg.model === '<synthetic>') rec.el.classList.add('synthetic');
      renderTextNow(rec, true);
    } else if (b.type === 'thinking' || b.type === 'redacted_thinking') {
      let rec = list.find((r) => r.kind === 'thinking' && !r.final);
      const t = b.thinking || '';
      if (!rec) { if (!t) continue; rec = makeThinking(S, parent); rec.kind = 'thinking'; list.push(rec); }
      if (t) rec.text = t;
      rec.final = true;
      renderTextNow(rec, true);
    } else if (b.type === 'tool_use' || b.type === 'server_tool_use' || b.type === 'mcp_tool_use') {
      const t = ensureTool(S, b.id, b.name, b.input, parent);
      t.streaming = false;
      if (!list.includes(t)) list.push(t);
      renderTool(t);
    } else if (b.type && b.type.endsWith('_tool_result') && b.tool_use_id) {
      applyToolResult(S, { tool_use_id: b.tool_use_id, content: b.content, is_error: !!b.is_error }, null, parent);
    }
  }
  if (!parent && msg.usage && !fromHistory) {
    const u = msg.usage;
    S.lastUsage = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.output_tokens || 0);
  }
}

// ---- user messages: prompts, tool results, command echoes
function onUser(S, o, fromHistory) {
  const parent = o.parent_tool_use_id || o.__parent || null;
  const c = o.message?.content;
  if (o.isReplay) {
    const t = typeof c === 'string' ? c : textOf(c);
    const i = S.sentQueue.findIndex((q) => q.text === t.trim());
    if (i >= 0) { const [q] = S.sentQueue.splice(i, 1); q.el.classList.remove('queued'); if (o.uuid) q.el.dataset.uuid = o.uuid; }
    return;
  }
  if (fromHistory && o.isMeta) {
    const t = typeof c === 'string' ? c : textOf(c);
    if (/<local-command-stdout>/.test(t)) renderLocalOutput(S, t);
    return;
  }
  const texts = [], imgs = [];
  if (typeof c === 'string') texts.push(c);
  else if (Array.isArray(c)) {
    for (const b of c) {
      if (b.type === 'tool_result') applyToolResult(S, b, o.tool_use_result ?? o.toolUseResult, parent);
      else if (b.type === 'text') texts.push(b.text);
      else if (b.type === 'image') imgs.push(b);
    }
  }
  const text = stripReminders(texts.join('\n\n'));
  if (!text && !imgs.length) return;
  if (parent) {
    const a = ensureAgent(S, parent);
    if (!a.promptSet) { a.promptSet = true; setAgentPrompt(a, text); }
    return;
  }
  if (o.isSynthetic && !fromHistory) return;
  if (o.isCompactSummary) {
    S.append(h('details.msg.thinking', null, h('summary', { text: 'Summary of the earlier conversation' }), h('div.thinking-body.prose', { html: MD.render(text, { cwd: S.cwd }) })));
    return;
  }
  renderUserContent(S, text, imgs.map((b) => b.source?.type === 'base64' ? `data:${b.source.media_type};base64,${b.source.data}` : b.source?.url), o);
}

function renderUserContent(S, text, imgs, o) {
  // Command / shell / notification envelopes the CLI writes into the transcript.
  const cmd = text.match(/<command-name>([\s\S]*?)<\/command-name>/);
  if (cmd) {
    const args = (text.match(/<command-args>([\s\S]*?)<\/command-args>/) || [])[1] || '';
    S.append(userBubble(S, `${cmd[1].trim()} ${args.trim()}`.trim(), [], true));
    return;
  }
  if (/<local-command-stdout>|<local-command-stderr>/.test(text)) return renderLocalOutput(S, text);
  if (/<local-command-caveat>/.test(text)) return;
  const bi = text.match(/<bash-input>([\s\S]*?)<\/bash-input>/);
  if (bi) { S.lastShell = shellCard(S, bi[1]); S.append(S.lastShell.el); return; }
  if (/<bash-stdout>|<bash-stderr>/.test(text)) {
    const out = (text.match(/<bash-stdout>([\s\S]*?)<\/bash-stdout>/) || [])[1] || '';
    const err = (text.match(/<bash-stderr>([\s\S]*?)<\/bash-stderr>/) || [])[1] || '';
    if (S.lastShell) S.lastShell.done(out, err);
    return;
  }
  const tn = text.match(/<task-notification>([\s\S]*?)<\/task-notification>/);
  if (tn) {
    const summary = (tn[1].match(/<summary>([\s\S]*?)<\/summary>/) || [])[1] || 'Background task finished';
    S.append(h('div.interrupted', { text: '⟲ ' + summary.trim() }));
    return;
  }
  if (/^\[Request interrupted by user/.test(text)) { S.append(h('div.interrupted', { text: 'Interrupted by you' })); return; }
  if (text.startsWith('<') && /^<[a-z-]+>/.test(text) && !imgs.length) return; // other internal envelopes
  const b = userBubble(S, text, imgs, false);
  if (o.uuid) b.dataset.uuid = o.uuid;
  S.append(b);
}

function renderLocalOutput(S, t) {
  const out = (t.match(/<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/) || [])[1];
  const err = (t.match(/<local-command-stderr>([\s\S]*?)<\/local-command-stderr>/) || [])[1];
  const body = (out || err || '').trim();
  if (!body) return;
  const rec = makeText(S, null);
  rec.text = body; rec.final = true;
  renderTextNow(rec, true);
}

function userBubble(S, text, imgs, isCmd) {
  const bubble = h('div.user-bubble' + (isCmd ? '.cmd' : ''));
  if (imgs && imgs.length) bubble.append(h('div.imgs', null, imgs.map((src) => h('img', { src, onclick: () => lightbox(src) }))));
  if (text) bubble.append(document.createTextNode(text));
  bubble.append(h('div.msg-actions', null, h('button.mini-btn', { text: 'Copy', onclick: () => { native('copy', { text }); toast('Copied'); } })));
  return h('div.user-row', null, bubble);
}

function notice(text, kind, detail) {
  return h('div.notice' + (kind ? '.' + kind : ''), null, h('div', null, text, detail ? h('pre', { text: detail }) : null));
}

// ---- system messages
function onSystem(S, o, fromHistory) {
  switch (o.subtype) {
    case 'init':
      S.sys = o; S.model = o.model; S.mode = o.permissionMode || S.mode; S.live = true;
      if (o.cwd) S.realCwd = o.cwd;
      if (S === current) updateChrome();
      return;
    case 'status':
      if (o.permissionMode) { S.mode = o.permissionMode; if (S === current) updateChrome(); }
      if (o.status === 'compacting') { setBusy(S, true); S.verb = 'Compacting conversation'; }
      if (o.compact_result === 'failed') S.append(notice('Compaction failed: ' + (o.compact_error || 'unknown error'), 'error'));
      return;
    case 'compact_boundary': {
      const md = o.compact_metadata || o.compactMetadata || {};
      S.append(h('div.divider', { text: `Conversation compacted${md.pre_tokens ? ` · ${fmtTok(md.pre_tokens)} → ${fmtTok(md.post_tokens || 0)} tokens` : ''}` }));
      return;
    }
    case 'local_command': {
      const t = o.content || '';
      if (/<local-command-stdout>/.test(t)) renderLocalOutput(S, t);
      return;
    }
    case 'local_command_output': {
      const rec = makeText(S, null); rec.text = o.content || ''; rec.final = true; renderTextNow(rec, true);
      return;
    }
    case 'informational':
      if (o.content) S.append(h('div.interrupted', { text: o.content }));
      return;
    case 'api_retry':
      S.verb = `Retrying (${o.attempt}/${o.max_retries})${o.error_status ? ' · HTTP ' + o.error_status : ''}`;
      return;
    case 'api_error':
      S.append(notice('API error: ' + (o.content || o.error?.message || ''), 'error'));
      return;
    case 'thinking_tokens':
      S.thinkTok = o.estimated_tokens || 0;
      return;
    case 'commands_changed':
      if (S.init) S.init.commands = o.commands;
      return;
    case 'permission_denied': {
      const t = S.tools.get(o.tool_use_id);
      if (t) { t.status = 'denied'; t.denyMsg = o.message; renderTool(t); }
      return;
    }
    case 'task_started': return onTask(S, o.task_id, { toolId: o.tool_use_id, desc: o.description, type: o.task_type, subagent: o.subagent_type, status: 'running', start: Date.now(), bg: o.is_backgrounded, prompt: o.prompt, workflow: o.workflow_name, skip: o.skip_transcript });
    case 'task_progress': return onTask(S, o.task_id, { toolId: o.tool_use_id, last: o.description, lastTool: o.last_tool_name, usage: o.usage, summary: o.summary });
    case 'task_updated': return onTask(S, o.task_id, { status: o.patch?.status, error: o.patch?.error, bg: o.patch?.is_backgrounded, desc: o.patch?.description });
    case 'task_notification': return onTask(S, o.task_id, { toolId: o.tool_use_id, status: o.status, summary: o.summary, output: o.output_file, usage: o.usage, end: Date.now() });
    case 'background_tasks_changed':
      S.bgTasks = o.tasks || [];
      for (const t of S.bgTasks) onTask(S, t.task_id, { type: t.task_type, desc: t.description, subagent: t.subagent_type, status: 'running', bg: true });
      for (const [id, t] of S.tasks) if (t.status === 'running' && t.bg && !S.bgTasks.some((b) => b.task_id === id)) t.bgGone = true;
      return;
    case 'notification':
      if (o.message || o.text) toast(o.message || o.text);
      return;
    case 'ui_status':
      S.usageText = o.text || '';
      return;
    case 'mirror_error':
      return;
  }
}

function onResult(S, o) {
  setBusy(S, false);
  // Local slash commands are not echoed back, so release their bubbles here.
  S.sentQueue = S.sentQueue.filter((q) => { if (q.text.startsWith('/')) { q.el.classList.remove('queued'); return false; } return true; });
  S.cur = {};
  if (o.total_cost_usd != null) S.cost = o.total_cost_usd;
  if (o.is_error || (o.subtype && o.subtype !== 'success')) {
    const why = { error_max_turns: 'Reached the maximum number of turns.', error_max_budget_usd: 'Reached the budget limit.', error_during_execution: 'The turn ended with an error.' }[o.subtype] || 'Error';
    const detail = Array.isArray(o.errors) ? o.errors.join('\n') : (typeof o.result === 'string' ? o.result : '');
    if (!/interrupt/i.test(detail)) S.append(notice(why, 'error', detail));
  }
  for (const t of S.tools.values()) if (t.status === 'running' && !t.bgTask && !t.parent) { t.status = 'done'; renderTool(t); }
  if (S.live) S.request('get_context_usage').then((r) => { if (r) { S.ctx = r; if (S === current) { updateChrome(); renderActivity(); } } });
}

function onExit(S, o) {
  const wasBusy = S.busy;
  S.live = false; S.warming = false; setBusy(S, false);
  for (const q of S.sentQueue) q.el.classList.remove('queued');
  S.sentQueue = [];
  for (const id of [...S.pending.keys()]) removePending(S, id);
  for (const t of S.tools.values()) if (t.status === 'running' || t.status === 'pending') { t.status = 'error'; renderTool(t); }
  const code = o.code;
  if (code !== 0 && code !== 15 && code !== 143 && code !== 130 && code !== 2) {
    S.append(notice(`Claude Code exited (code ${code}).`, 'error', (o.stderr || '').trim().slice(-1500)));
  } else if (wasBusy) {
    S.append(h('div.interrupted', { text: 'Session process ended.' }));
  }
  if (S === current) updateChrome();
}

function setBusy(S, v) {
  if (S.busy === v) return;
  S.busy = v;
  if (v) { S.turnStart = Date.now(); S.thinkTok = 0; S.outTok = 0; }
  S.working.hidden = !v;
  if (S === current) updateChrome();
}

// ---------------------------------------------------------------- text & thinking blocks
function makeText(S, parent) {
  const body = h('div.prose');
  const wrap = h('div.msg.assistant-text', null, body);
  const rec = { kind: 'text', text: '', el: wrap, body, S, parent, final: false };
  wrap.append(h('div.msg-actions', null, h('button.mini-btn', { text: 'Copy', onclick: () => { native('copy', { text: rec.text }); toast('Copied'); } })));
  S.append(wrap, parent);
  return rec;
}
function makeThinking(S, parent) {
  const body = h('div.thinking-body.prose');
  const sum = h('summary', { text: 'Thinking…' });
  const el = h('details.msg.thinking', null, sum, body);
  const rec = { kind: 'thinking', text: '', el, body, sum, S, parent, final: false, start: Date.now() };
  S.append(el, parent);
  return rec;
}
const textQueue = new Set();
let textRaf = 0;
function scheduleText(rec) {
  textQueue.add(rec);
  if (!textRaf) textRaf = setTimeout(() => { textRaf = 0; const q = [...textQueue]; textQueue.clear(); q.forEach((r) => renderTextNow(r, false)); if (current) current.scroll(); }, 45);
}
function renderTextNow(rec, final) {
  if (!final && rec.final) return;          // a stale streaming frame landing after the final copy
  if (final) textQueue.delete(rec);
  if (rec.kind === 'thinking') {
    rec.body.innerHTML = MD.render(rec.text, { cwd: rec.S.cwd });
    if (final) {
      if (!rec.text.trim()) { rec.el.remove(); return; }   // redacted thinking: nothing to show
      const secs = Math.max(1, Math.round((Date.now() - rec.start) / 1000));
      rec.sum.textContent = rec.S.loadingHistory || !rec.streamedOnce ? 'Thought process' : `Thought for ${secs}s`;
    } else { rec.streamedOnce = true; rec.sum.textContent = 'Thinking…'; }
    return;
  }
  rec.body.innerHTML = MD.render(rec.text, { cwd: rec.S.cwd });
  rec.body.classList.toggle('cursor-host', !final);
  MD.enhance(rec.body, { final });
  if (!final && rec.body.lastElementChild) rec.body.lastElementChild.classList.add('cursor');
}
function finalizeAllText(S) {
  for (const list of S.msgBlocks.values()) for (const r of list) if ((r.kind === 'text') && !r.final) { r.final = true; renderTextNow(r, true); }
}

// ---------------------------------------------------------------- tools
const TOOL_VERBS = { Bash: 'Running command', Read: 'Reading', Write: 'Writing file', Edit: 'Editing', MultiEdit: 'Editing', Grep: 'Searching', Glob: 'Finding files', WebFetch: 'Fetching', WebSearch: 'Searching the web', Agent: 'Delegating', Task: 'Delegating', TodoWrite: 'Planning' };
function verbFor(name) { return TOOL_VERBS[name] || (name?.startsWith('mcp__') ? 'Calling ' + name.split('__')[1] : 'Working'); }
const isAgentTool = (name) => name === 'Agent' || name === 'Task';

function ensureTool(S, id, name, input, parent) {
  let t = S.tools.get(id);
  if (!t) {
    if (isAgentTool(name)) {
      const a = ensureAgent(S, id, parent);
      t = a.tool;
    } else {
      t = { id, name, input: input || null, parent, status: 'running', S, start: Date.now() };
      t.el = h('div.tool', { dataset: { status: 'running', id } });
      t.head = h('div.tool-head');
      t.bodyEl = h('div.tool-body', { hidden: true });
      t.el.append(t.head, t.bodyEl);
      t.head.addEventListener('click', () => toggleTool(t));
      S.tools.set(id, t);
      S.append(t.el, parent);
    }
  }
  if (name && name !== '?') t.name = name;
  if (input && Object.keys(input).length) t.input = input;
  if (!t.agent) renderTool(t); else renderAgent(t.agent);
  return t;
}

function previewToolInput(t) {
  if (!t.partial || t.agent) return;
  if (t._pv && Date.now() - t._pv < 120) return;
  t._pv = Date.now();
  // Best-effort partial parse for a live preview of the command / path.
  const m = t.partial.match(/"(command|file_path|pattern|url|query|description)"\s*:\s*"((?:[^"\\]|\\.)*)/);
  if (m) { t.preview = m[2].replace(/\\n/g, ' ').replace(/\\"/g, '"'); renderToolHead(t); }
}

function toggleTool(t) {
  t.open = !t.open;
  t.el.classList.toggle('open', t.open);
  t.bodyEl.hidden = !t.open;
  if (t.open) renderToolBody(t);
}

function rel(S, p) {
  if (!p) return '';
  const norm = (x) => (x || '').replace(/^\/private(?=\/(tmp|var)\/)/, '');
  for (const base of [S.cwd, S.realCwd]) {
    if (base && norm(p).startsWith(norm(base) + '/')) return norm(p).slice(norm(base).length + 1);
  }
  if (config.home && p.startsWith(config.home + '/')) return '~' + p.slice(config.home.length);
  return p;
}

function toolSummary(t) {
  const i = t.input || {}, S = t.S;
  const n = t.name || '';
  if (t.preview && !t.input) return { text: t.preview };
  switch (n) {
    case 'Bash': return { text: i.description || i.command || '', title: i.command, plain: !!i.description };
    case 'BashOutput': return { text: i.bash_id || '' };
    case 'Read': return { text: rel(S, i.file_path) + (i.offset ? ` :${i.offset}` : '') + (i.limit ? `+${i.limit}` : '') };
    case 'Write': case 'Edit': case 'MultiEdit': case 'NotebookEdit': return { text: rel(S, i.file_path || i.notebook_path) };
    case 'Grep': return { text: `${i.pattern || ''}${i.glob ? '  ' + i.glob : ''}${i.path ? '  in ' + rel(S, i.path) : ''}` };
    case 'Glob': return { text: (i.pattern || '') + (i.path ? '  in ' + rel(S, i.path) : '') };
    case 'WebFetch': return { text: i.url || '' };
    case 'WebSearch': return { text: i.query || '', plain: true };
    case 'TodoWrite': return { text: `${(i.todos || []).length} items`, plain: true };
    case 'Skill': return { text: i.skill || i.command || '', plain: true };
    case 'ToolSearch': return { text: i.query || '' };
    case 'AskUserQuestion': return { text: (i.questions || [])[0]?.question || '', plain: true };
    case 'ExitPlanMode': return { text: 'Plan ready for review', plain: true };
    case 'EnterPlanMode': return { text: 'Switching to plan mode', plain: true };
    case 'SendMessage': return { text: `→ ${i.to || ''}${i.summary ? ': ' + i.summary : ''}`, plain: true };
    case 'Monitor': case 'TaskStop': case 'KillShell': return { text: i.description || i.task_id || i.shell_id || '' };
  }
  const first = Object.values(i).find((v) => typeof v === 'string');
  return { text: first ? first.slice(0, 200) : '' };
}

function toolLabel(name) {
  if (!name) return 'Tool';
  if (name.startsWith('mcp__')) { const [, srv, tool] = name.split('__'); return `${srv.replace(/^claude_ai_/, '')} · ${tool}`; }
  return name;
}

function renderToolHead(t) {
  const sum = toolSummary(t);
  const ico = t.status === 'running' ? h('span.spin') : h('span.dot');
  const meta = h('span.tool-meta');
  const kids = [h('span.tool-ico', null, ico), h('span.tool-name', { text: toolLabel(t.name) })];
  if (t.input?.run_in_background || t.bgTask) kids.push(h('span.badge.accent', { text: 'background' }));
  if (t.status === 'pending') kids.push(h('span.badge.warn', { text: 'needs approval' }));
  if (t.status === 'denied') kids.push(h('span.badge.warn', { text: 'denied' }));
  kids.push(h('span.tool-sum' + (sum.plain ? '.plain' : ''), { text: sum.text, title: sum.title || sum.text }), meta, h('span.chev', { text: '›' }));
  t.head.replaceChildren(...kids);
  t.metaEl = meta;
  updateToolMeta(t);
}

function updateToolMeta(t) {
  if (!t.metaEl) return;
  const parts = [];
  if (t.status === 'running' && t.elapsed) parts.push(Math.round(t.elapsed) + 's');
  if (t.status !== 'running' && t.resultSummary) parts.push(t.resultSummary);
  t.metaEl.textContent = parts.join(' · ');
  if (t.status === 'error') t.metaEl.classList.add('err');
}

function renderTool(t) {
  if (t.agent) return renderAgent(t.agent);
  t.el.dataset.status = t.status;
  t.resultSummary = resultSummary(t);
  renderToolHead(t);
  // Some tools are more useful expanded by default.
  if (t.name === 'TodoWrite' && t.input?.todos) {
    if (!t.todoEl) { t.todoEl = h('ul.todos'); t.el.append(t.todoEl); }
    t.todoEl.replaceChildren(...t.input.todos.map((td) => h('li.' + (td.status || 'pending'), null, h('span.box', { text: td.status === 'completed' ? '✓' : td.status === 'in_progress' ? '◐' : '○' }), h('span', { text: td.status === 'in_progress' && td.activeForm ? td.activeForm : td.content }))));
  }
  if (t.name === 'ExitPlanMode' && t.input?.plan && !t.planShown) {
    t.planShown = true; t.open = true; t.el.classList.add('open'); t.bodyEl.hidden = false;
  }
  if (t.open) renderToolBody(t);
}

function resultSummary(t) {
  if (t.status === 'denied') return 'denied';
  const r = t.structured;
  const txt = typeof t.result === 'string' ? t.result : textOf(t.result);
  if (t.status === 'error') return 'error';
  switch (t.name) {
    case 'Read': { const n = r?.file?.numLines ?? (txt ? txt.split('\n').length : null); return n != null ? `${n} lines` : ''; }
    case 'Grep': { if (r?.numFiles != null) return `${r.numFiles} files`; if (r?.numLines != null) return `${r.numLines} lines`; return ''; }
    case 'Glob': { if (r?.numFiles != null) return `${r.numFiles} files`; return ''; }
    case 'Edit': case 'MultiEdit': case 'Write': {
      const patch = r?.structuredPatch;
      if (Array.isArray(patch) && patch.length) {
        let a = 0, d = 0; for (const hk of patch) for (const l of hk.lines || []) { if (l[0] === '+') a++; else if (l[0] === '-') d++; }
        return `+${a} −${d}`;
      }
      if (t.name === 'Write' && t.input?.content) return `${t.input.content.split('\n').length} lines`;
      return '';
    }
    case 'Bash': { if (r?.interrupted) return 'interrupted'; return ''; }
  }
  return '';
}

function applyToolResult(S, b, structured, parent) {
  let t = S.tools.get(b.tool_use_id);
  if (!t) t = ensureTool(S, b.tool_use_id, '?', null, parent);
  t.result = b.content;
  t.structured = structured && typeof structured === 'object' ? structured : null;
  t.isError = !!b.is_error;
  if (t.agent) return agentResult(t.agent, b);
  if (t.status !== 'denied') t.status = t.isError ? 'error' : 'done';
  if (t.structured?.backgroundTaskId) t.bgTask = t.structured.backgroundTaskId;
  t.end = Date.now();
  renderTool(t);
}

function renderToolBody(t) {
  const S = t.S, i = t.input || {};
  const kids = [];
  const resText = typeof t.result === 'string' ? t.result : textOf(t.result);
  const resImgs = imagesOf(t.result);
  const r = t.structured;
  if (t.denyMsg) kids.push(notice(t.denyMsg));
  switch (t.name) {
    case 'Bash': {
      const term = h('div.term');
      term.append(h('pre.cmdline', { text: i.command || '' }));
      const out = r && (r.stdout != null || r.stderr != null) ? r.stdout || '' : resText;
      const err = r && r.stderr ? r.stderr : '';
      if (t.result == null && t.status === 'running') term.append(h('pre.muted', { text: 'Running…' }));
      else if (!out && !err) term.append(h('pre.muted', { text: '(no output)' }));
      if (out) term.append(...truncatedPre(out, t.isError && !err ? 'stderr' : ''));
      if (err) term.append(...truncatedPre(err, 'stderr'));
      kids.push(term);
      break;
    }
    case 'Edit': case 'MultiEdit': {
      const patch = r?.structuredPatch;
      if (Array.isArray(patch) && patch.length) kids.push(patchView(patch));
      else if (t.name === 'Edit') kids.push(diffView(i.old_string || '', i.new_string || ''));
      else for (const e of i.edits || []) kids.push(diffView(e.old_string || '', e.new_string || ''));
      if (t.isError) kids.push(h('pre.kv', { text: resText }));
      kids.push(fileLink(S, i.file_path));
      break;
    }
    case 'Write': {
      const patch = r?.structuredPatch;
      if (Array.isArray(patch) && patch.length && r?.type === 'update') kids.push(patchView(patch));
      else kids.push(codeView(i.content || '', extOf(i.file_path)));
      if (t.isError) kids.push(h('pre.kv', { text: resText }));
      kids.push(fileLink(S, i.file_path));
      break;
    }
    case 'Read': {
      if (resImgs.length) resImgs.forEach((src) => kids.push(h('img.result-img', { src, onclick: () => lightbox(src) })));
      else if (resText) kids.push(...wrapTerm(truncatedPre(resText, t.isError ? 'stderr' : '')));
      kids.push(fileLink(S, i.file_path));
      break;
    }
    case 'TodoWrite': break;
    case 'ExitPlanMode': {
      const p = h('div.prose', { html: MD.render(i.plan || '', { cwd: S.cwd }) });
      MD.enhance(p, { final: true });
      kids.push(p);
      break;
    }
    case 'AskUserQuestion': {
      const answers = r?.answers || {};
      for (const q of i.questions || []) kids.push(h('div.q-block', null, h('div.q-text', { text: q.question }), h('div', { text: '→ ' + (answers[q.question] || '(no answer)') })));
      break;
    }
    default: {
      const inputStr = Object.keys(i).length ? JSON.stringify(i, null, 2) : '';
      if (inputStr) { kids.push(h('div.label', { text: 'Input' }), h('pre.kv', { text: inputStr })); }
      if (resImgs.length) resImgs.forEach((src) => kids.push(h('img.result-img', { src, onclick: () => lightbox(src) })));
      if (resText) { kids.push(h('div.label', { text: t.isError ? 'Error' : 'Result' })); kids.push(...wrapTerm(truncatedPre(resText, t.isError ? 'stderr' : ''))); }
      else if (t.result == null && t.status === 'running') kids.push(h('div.label', { text: 'Running…' }));
    }
  }
  t.bodyEl.replaceChildren(...kids);
}

function wrapTerm(nodes) { const d = h('div.term'); d.append(...nodes); return [d]; }
function truncatedPre(text, cls, max = 120) {
  const lines = String(text).split('\n');
  const pre = h('pre' + (cls ? '.' + cls : ''));
  if (lines.length <= max) { pre.textContent = text; return [pre]; }
  pre.textContent = lines.slice(0, max).join('\n');
  const btn = h('button.more-btn', { text: `Show all ${lines.length} lines`, onclick: () => { pre.textContent = text; btn.remove(); } });
  return [pre, btn];
}
function extOf(p) { const m = (p || '').match(/\.([A-Za-z0-9]+)$/); return m ? m[1] : ''; }
function codeView(code, lang) {
  const lines = code.split('\n');
  const shown = lines.length > 300 ? lines.slice(0, 300).join('\n') : code;
  const block = h('div.code-block', null, h('div.code-head', null, h('span', { text: lang || 'text' }), h('button.mini-btn.copy-code', { text: 'Copy' })), h('pre', null, h('code.hljs', { html: MD.highlight(shown, lang) })));
  block.dataset.raw = code;
  if (lines.length > 300) block.append(h('button.more-btn', { text: `Show all ${lines.length} lines`, onclick: (e) => { block.querySelector('code').innerHTML = MD.highlight(code, lang); e.target.remove(); } }));
  return block;
}
function fileLink(S, p) {
  if (!p) return null;
  return h('div', { style: 'margin-top:6px' }, h('button.mini-btn', { text: 'Open ' + rel(S, p), onclick: () => native('openPath', { k: S.k, path: p }) }), h('button.mini-btn', { text: 'Reveal', onclick: () => native('openPath', { k: S.k, path: p, reveal: true }) }));
}

// ---- diffs
function patchView(patch) {
  const rows = [];
  for (const hk of patch) {
    rows.push(h('tr.hunk', null, h('td', { colspan: 4, text: `@@ -${hk.oldStart},${hk.oldLines} +${hk.newStart},${hk.newLines} @@` })));
    let o = hk.oldStart, n = hk.newStart;
    for (const l of hk.lines || []) {
      const sign = l[0], body = l.slice(1);
      if (sign === '+') rows.push(diffRow('add', '', n++, '+', body));
      else if (sign === '-') rows.push(diffRow('del', o++, '', '−', body));
      else if (sign === '\\') continue;
      else rows.push(diffRow('', o++, n++, ' ', body));
    }
  }
  return h('div.diff', null, h('table', null, h('tbody', null, rows)));
}
function diffRow(cls, a, b, sign, text) {
  return h('tr' + (cls ? '.' + cls : ''), null, h('td.ln', { text: String(a) }), h('td.ln', { text: String(b) }), h('td.sign', { text: sign }), h('td.code', { text }));
}
function diffView(a, b) {
  const A = a.split('\n'), B = b.split('\n');
  const rows = [];
  if (A.length * B.length > 250000) {
    A.forEach((l) => rows.push(diffRow('del', '', '', '−', l)));
    B.forEach((l) => rows.push(diffRow('add', '', '', '+', l)));
  } else {
    // LCS line diff.
    const n = A.length, m = B.length;
    const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = A[i] === B[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && A[i] === B[j]) { rows.push(diffRow('', i + 1, j + 1, ' ', A[i])); i++; j++; }
      else if (j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) { rows.push(diffRow('add', '', j + 1, '+', B[j])); j++; }
      else { rows.push(diffRow('del', i + 1, '', '−', A[i])); i++; }
    }
  }
  return h('div.diff', null, h('table', null, h('tbody', null, rows)));
}

// ---- local shell ("!" bash mode)
function shellCard(S, cmd) {
  const term = h('div.term', null, h('pre.cmdline', { text: cmd }));
  const pending = h('pre.muted', { text: 'Running…' });
  term.append(pending);
  const el = h('div.msg', null, term);
  return {
    el,
    done(out, err) {
      pending.remove();
      if (!out && !err) term.append(h('pre.muted', { text: '(no output)' }));
      if (out) term.append(...truncatedPre(out, ''));
      if (err) term.append(...truncatedPre(err, 'stderr'));
    },
  };
}

// ---------------------------------------------------------------- agents (subagents)
function ensureAgent(S, toolId, parent) {
  let a = S.agents.get(toolId);
  if (a) return a;
  const tool = { id: toolId, name: 'Agent', input: null, parent: parent || null, status: 'running', S, start: Date.now() };
  a = { toolId, tool, S, status: 'running', open: false, start: Date.now() };
  tool.agent = a;
  a.el = h('div.agent', { dataset: { status: 'running', id: toolId } });
  a.head = h('div.agent-head');
  a.live = h('div.agent-live');
  a.body = h('div.agent-body', { hidden: true });
  a.promptEl = h('details.agent-prompt', { hidden: true }, h('summary', { text: 'Prompt' }));
  a.children = h('div.agent-children');
  a.resultEl = h('div.agent-result', { hidden: true });
  a.body.append(a.promptEl, a.children, a.resultEl);
  a.el.append(a.head, a.live, a.body);
  a.head.addEventListener('click', (e) => { if (e.target.closest('.stop-btn')) return; toggleAgent(a); });
  S.agents.set(toolId, a);
  S.tools.set(toolId, tool);
  S.append(a.el, parent || null);
  renderAgent(a);
  return a;
}

function toggleAgent(a) {
  a.open = !a.open;
  a.el.classList.toggle('open', a.open);
  a.body.hidden = !a.open;
  if (a.open && !a.children.childElementCount && !a.loadedSub) loadSubagentHistory(a);
}

async function loadSubagentHistory(a) {
  a.loadedSub = true;
  const agentId = a.agentId || (textOf(a.tool.result).match(/agentId:\s*([a-z0-9]+)/) || [])[1] || a.tool.structured?.agentId;
  if (!agentId) return;
  const lines = await native('subagent', { k: a.S.k, agentId });
  if (!Array.isArray(lines) || !lines.length) return;
  for (const line of lines) {
    try { const o = JSON.parse(line); o.__parent = a.toolId; o.isMeta = false; handleEvent(a.S, o, true); } catch (e) { /* skip */ }
  }
}

function setAgentPrompt(a, text) {
  if (!text) return;
  a.promptEl.hidden = false;
  const p = h('div.prose', { html: MD.render(text, { cwd: a.S.cwd }) });
  a.promptEl.append(p);
}

function renderAgent(a) {
  const i = a.tool.input || {};
  const task = a.taskId ? a.S.tasks.get(a.taskId) : null;
  const status = a.status;
  a.el.dataset.status = status;
  const running = status === 'running';
  const ico = running ? h('span.spin') : h('span.a-ico', { text: status === 'completed' || status === 'done' ? '✓' : status === 'stopped' || status === 'killed' ? '■' : '✕' });
  const u = task?.usage || a.usage;
  const stats = [];
  if (u?.tool_uses != null) stats.push(`${u.tool_uses} tool${u.tool_uses === 1 ? '' : 's'}`);
  if (u?.total_tokens) stats.push(fmtTok(u.total_tokens) + ' tok');
  const dur = u?.duration_ms ?? ((a.end || Date.now()) - a.start);
  if (dur) stats.push(fmtDur(dur));
  const kids = [h('span.tool-ico', null, ico), h('span.badge.accent', { text: i.subagent_type || task?.subagent || 'agent' }), h('span.agent-title', { text: i.description || task?.desc || 'Subagent' })];
  if (task?.bg || i.run_in_background) kids.push(h('span.badge', { text: 'background' }));
  kids.push(h('span.agent-stats', { text: stats.join(' · ') }));
  if (running && a.taskId && a.S.live) kids.push(h('button.stop-btn', { text: 'Stop', onclick: () => { a.S.request('stop_task', { task_id: a.taskId }); toast('Stopping agent…'); } }));
  kids.push(h('span.chev', { text: '›' }));
  a.head.replaceChildren(...kids);
  a.live.textContent = running ? (task?.last ? '↳ ' + task.last : i.prompt ? '↳ ' + i.prompt.split('\n')[0].slice(0, 160) : '') : '';
  if (i.prompt && !a.promptSet) { a.promptSet = true; setAgentPrompt(a, i.prompt); }
}

function agentResult(a, b) {
  const text = textOf(b.content);
  const m = text.match(/agentId:\s*([a-z0-9]+)/);
  if (m) a.agentId = m[1];
  if (/Async agent launched|running in the background/i.test(text)) { a.bgLaunched = true; renderAgent(a); return; }
  if (a.status !== 'running' && a.resultSet) return;   // task_notification already gave a clean summary
  a.status = b.is_error ? 'failed' : 'completed';
  a.end = Date.now();
  const clean = cleanAgentReport(text);
  if (clean) setAgentResult(a, clean);
  renderAgent(a);
}
/** Strip the harness framing around a subagent's report (preamble, indentation, ids, usage). */
function cleanAgentReport(text) {
  let t = text.replace(/<tools-used-before-summary>[\s\S]*?<\/tools-used-before-summary>/g, '');
  const m = t.match(/\[Subagent hand-back\][\s\S]*?The report follows:\n/);
  if (m) t = t.slice(m.index + m[0].length);
  t = t.replace(/\n?agentId:[\s\S]*$/, '').replace(/<usage>[\s\S]*?<\/usage>/g, '');
  const lines = t.split('\n');
  const ind = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
  if (ind > 0 && ind < 12) t = lines.map((l) => l.slice(ind)).join('\n');
  return t.trim();
}
function setAgentResult(a, md) {
  a.resultSet = true;
  a.resultEl.hidden = false;
  a.resultEl.innerHTML = MD.render(md, { cwd: a.S.cwd });
  MD.enhance(a.resultEl, { final: true });
}

function onTask(S, id, patch) {
  if (!id) return;
  let t = S.tasks.get(id);
  if (!t) { t = { id, status: 'running', start: Date.now() }; S.tasks.set(id, t); }
  for (const [k, v] of Object.entries(patch)) if (v !== undefined && v !== null) t[k] = v;
  if (t.toolId) {
    const a = S.agents.get(t.toolId);
    if (a) {
      a.taskId = id;
      if (t.usage) a.usage = t.usage;
      if (patch.status) a.status = { killed: 'stopped' }[patch.status] || patch.status;
      if (patch.end) a.end = patch.end;
      if (patch.summary && patch.status) setAgentResult(a, patch.summary);
      renderAgent(a);
    } else {
      const tool = S.tools.get(t.toolId);
      if (tool) { tool.bgTask = id; if (patch.status && patch.status !== 'running') { tool.status = patch.status === 'completed' ? 'done' : 'error'; } renderTool(tool); }
    }
  }
}

// ---------------------------------------------------------------- control requests (permissions etc.)
function onControlResponse(S, o) {
  const r = o.response || {};
  const id = r.request_id;
  if (id === 'init') {
    if (r.subtype === 'success' && r.response) {
      S.init = r.response;
      if (r.response.models) { lastModels = r.response.models; store.set('models', lastModels); }
      if (r.response.current_permission_mode) S.mode = r.response.current_permission_mode;
      S.live = true;
      for (const pr of r.response.pending_permission_requests || []) onControlRequest(S, pr);
    } else if (r.subtype === 'error') {
      S.append(notice('Failed to initialize Claude Code: ' + r.error, 'error'));
    }
    if (S === current) updateChrome();
    return;
  }
  const w = S.waiters.get(id);
  if (w) { S.waiters.delete(id); w(r.subtype === 'success' ? (r.response || {}) : null); if (r.subtype === 'error') toast(r.error || 'Request failed'); }
}

function onControlRequest(S, o) {
  const req = o.request || {};
  switch (req.subtype) {
    case 'can_use_tool': {
      const t = S.tools.get(req.tool_use_id);
      if (t && !t.agent) { t.status = 'pending'; renderTool(t); }
      S.pending.set(o.request_id, { req, id: o.request_id, at: Date.now() });
      break;
    }
    case 'elicitation':
      S.pending.set(o.request_id, { req, id: o.request_id, at: Date.now() });
      break;
    case 'request_user_dialog':
      S.respond(o.request_id, { behavior: 'cancelled' });
      return;
    case 'hook_callback':
      S.respond(o.request_id, {});
      return;
    case 'mcp_message':
      S.respondError(o.request_id, 'No SDK MCP servers in this host');
      return;
    default:
      S.respondError(o.request_id, 'Unsupported request: ' + req.subtype);
      return;
  }
  if (S === current) renderDock();
}

function removePending(S, id) {
  const p = S.pending.get(id);
  if (!p) return;
  S.pending.delete(id);
  const t = S.tools.get(p.req.tool_use_id);
  if (t && t.status === 'pending') { t.status = 'running'; renderTool(t); }
  if (S === current) renderDock();
}

function answerPermission(S, p, response) {
  S.respond(p.id, response);
  const t = S.tools.get(p.req.tool_use_id);
  if (t && !t.agent) { t.status = response.behavior === 'allow' ? 'running' : 'denied'; if (response.behavior === 'deny') t.denyMsg = response.message; renderTool(t); }
  S.pending.delete(p.id);
  renderDock();
  $('#input').focus();
}

function suggestionLabel(sug) {
  if (!sug) return null;
  if (sug.type === 'setMode') return sug.mode === 'acceptEdits' ? 'Allow all edits this session' : `Switch to ${sug.mode}`;
  if (sug.type === 'addRules') {
    const rules = (sug.rules || []).map((r) => r.ruleContent ? `${r.toolName}(${r.ruleContent})` : r.toolName).join(', ');
    const where = { session: 'this session', localSettings: 'this project (local)', projectSettings: 'this project', userSettings: 'all projects' }[sug.destination] || sug.destination;
    return `Always allow ${rules} · ${where}`;
  }
  if (sug.type === 'addDirectories') return `Allow access to ${(sug.directories || []).join(', ')}`;
  return null;
}

function renderDock() {
  const dock = $('#dock');
  const S = current;
  if (!S) { dock.replaceChildren(); return; }
  const cards = [];
  for (const p of S.pending.values()) cards.push(p.el || (p.el = buildPromptCard(S, p)));
  dock.replaceChildren(...cards);
  const first = cards[0];
  if (first) { const f = first.querySelector('[data-autofocus]'); if (f) setTimeout(() => f.focus(), 0); }
}

function buildPromptCard(S, p) {
  const req = p.req;
  if (req.subtype === 'elicitation') return elicitationCard(S, p);
  if (req.tool_name === 'AskUserQuestion') return questionCard(S, p);
  if (req.tool_name === 'ExitPlanMode') return planCard(S, p);
  const i = req.input || {};
  const name = req.display_name || req.tool_name;
  const card = h('div.prompt-card');
  const title = req.title || `Allow ${toolLabel(name)}?`;
  card.append(h('div.prompt-title', null, h('span', { text: '⚠︎' }), h('span', { text: title })));
  if (req.description && req.description !== title) card.append(h('div.prompt-sub', { text: req.description }));
  if (req.decision_reason) card.append(h('div.prompt-sub', { text: req.decision_reason }));
  if (req.blocked_path) card.append(h('div.prompt-sub', { text: 'Path: ' + req.blocked_path }));
  // Preview of what will happen.
  if (req.tool_name === 'Bash') card.append(h('div.term', null, h('pre.cmdline', { text: i.command || '' })));
  else if (req.tool_name === 'Edit') card.append(h('div.prompt-sub', { text: rel(S, i.file_path) }), diffView(i.old_string || '', i.new_string || ''));
  else if (req.tool_name === 'MultiEdit') { card.append(h('div.prompt-sub', { text: rel(S, i.file_path) })); (i.edits || []).forEach((e) => card.append(diffView(e.old_string || '', e.new_string || ''))); }
  else if (req.tool_name === 'Write') card.append(h('div.prompt-sub', { text: rel(S, i.file_path) }), codeView((i.content || '').split('\n').slice(0, 60).join('\n'), extOf(i.file_path)));
  else if (req.tool_name === 'WebFetch') card.append(h('pre.kv', { text: i.url || '' }));
  else card.append(h('pre.kv', { text: JSON.stringify(i, null, 2).slice(0, 4000) }));
  if (req.agent_id) card.append(h('div.prompt-sub', { text: 'Requested by a subagent' }));

  const fb = h('input.feedback', { placeholder: 'Tell Claude what to do instead (optional)' });
  const allow = h('button.btn.primary', { 'data-autofocus': true, onclick: () => answerPermission(S, p, { behavior: 'allow', updatedInput: i }) }, 'Allow', h('kbd', { text: '↩' }));
  const actions = [allow];
  for (const sug of req.permission_suggestions || []) {
    const label = suggestionLabel(sug);
    if (label) actions.push(h('button.btn', { text: label, onclick: () => answerPermission(S, p, { behavior: 'allow', updatedInput: i, updatedPermissions: [sug] }) }));
  }
  const deny = h('button.btn.danger', { onclick: () => answerPermission(S, p, { behavior: 'deny', message: fb.value.trim() || 'The user declined this action.', interrupt: !fb.value.trim() }) }, 'Deny', h('kbd', { text: 'esc' }));
  actions.push(deny, fb);
  fb.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); deny.click(); } e.stopPropagation(); });
  card.addEventListener('keydown', (e) => {
    if (e.target === fb) return;
    if (e.key === 'Enter') { e.preventDefault(); allow.click(); }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); deny.click(); }
  });
  card.append(h('div.prompt-actions', null, actions));
  return card;
}

function questionCard(S, p) {
  const req = p.req, i = req.input || {};
  const card = h('div.prompt-card.question');
  card.append(h('div.prompt-title', { text: 'Claude has a question' }));
  const state = (i.questions || []).map(() => ({ sel: new Set(), other: '' }));
  (i.questions || []).forEach((q, qi) => {
    const opts = h('div.q-opts');
    const otherIn = h('input.feedback.q-other', { placeholder: 'Other…' });
    (q.options || []).forEach((o) => {
      const b = h('button.q-opt', null, h('div.o-label', { text: o.label }), o.description ? h('div.o-desc', { text: o.description }) : null);
      b.addEventListener('click', () => {
        const st = state[qi];
        if (q.multiSelect) { st.sel.has(o.label) ? st.sel.delete(o.label) : st.sel.add(o.label); }
        else { st.sel.clear(); st.sel.add(o.label); otherIn.value = ''; st.other = ''; }
        opts.querySelectorAll('.q-opt').forEach((x, xi) => x.classList.toggle('sel', st.sel.has(q.options[xi].label)));
        if (!q.multiSelect && (i.questions || []).length === 1) submit.click();
      });
      opts.append(b);
    });
    otherIn.addEventListener('input', () => { state[qi].other = otherIn.value; if (!q.multiSelect && otherIn.value) { state[qi].sel.clear(); opts.querySelectorAll('.q-opt').forEach((x) => x.classList.remove('sel')); } });
    otherIn.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter') submit.click(); });
    card.append(h('div.q-block', null, h('div.q-head', null, q.header ? h('span.badge.accent', { text: q.header }) : null, h('span.q-text', { text: q.question })), opts, otherIn));
  });
  const submit = h('button.btn.primary', { text: 'Submit', onclick: () => {
    const answers = {};
    (i.questions || []).forEach((q, qi) => {
      const st = state[qi];
      const vals = [...st.sel];
      if (st.other.trim()) vals.push(st.other.trim());
      if (vals.length) answers[q.question] = vals.join(', ');
    });
    answerPermission(S, p, { behavior: 'allow', updatedInput: { ...i, answers } });
  } });
  const skip = h('button.btn', { text: 'Skip', onclick: () => answerPermission(S, p, { behavior: 'deny', message: 'The user chose not to answer.' }) });
  card.append(h('div.prompt-actions', null, submit, skip));
  return card;
}

function planCard(S, p) {
  const i = p.req.input || {};
  const card = h('div.prompt-card.plan');
  card.append(h('div.prompt-title', { text: 'Ready to code? Review the plan' }));
  const body = h('div.prose', { html: MD.render(i.plan || '', { cwd: S.cwd }) });
  MD.enhance(body, { final: true });
  card.append(body);
  const fb = h('input.feedback', { placeholder: 'Tell Claude what to change' });
  fb.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter') keep.click(); });
  const approveAuto = h('button.btn.primary', { 'data-autofocus': true, text: 'Yes, auto-accept edits', onclick: () => { answerPermission(S, p, { behavior: 'allow', updatedInput: i, updatedPermissions: [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }] }); S.mode = 'acceptEdits'; updateChrome(); } });
  const approve = h('button.btn', { text: 'Yes, ask before edits', onclick: () => { answerPermission(S, p, { behavior: 'allow', updatedInput: i, updatedPermissions: [{ type: 'setMode', mode: 'default', destination: 'session' }] }); S.mode = 'default'; updateChrome(); } });
  const keep = h('button.btn', { text: 'Keep planning', onclick: () => answerPermission(S, p, { behavior: 'deny', message: fb.value.trim() || 'The user wants to keep planning. Refine the plan.' }) });
  card.append(h('div.prompt-actions', null, approveAuto, approve, keep, fb));
  return card;
}

function elicitationCard(S, p) {
  const req = p.req;
  const card = h('div.prompt-card.question');
  card.append(h('div.prompt-title', { text: req.title || `${req.mcp_server_name} needs input` }));
  card.append(h('div.prompt-sub', { text: req.message || '' }));
  const fields = {};
  const props = req.requested_schema?.properties || {};
  for (const [k, def] of Object.entries(props)) {
    const input = def.enum ? h('select.feedback', null, def.enum.map((v) => h('option', { value: v, text: v }))) : def.type === 'boolean' ? h('input', { type: 'checkbox' }) : h('input.feedback', { placeholder: def.description || k });
    fields[k] = { input, def };
    card.append(h('div.label', { text: def.title || k }), input);
  }
  if (req.mode === 'url' && req.url) card.append(h('button.btn', { text: 'Open link', onclick: () => native('openURL', { url: req.url }) }));
  const accept = h('button.btn.primary', { text: 'Submit', onclick: () => {
    const content = {};
    for (const [k, { input, def }] of Object.entries(fields)) content[k] = def.type === 'boolean' ? input.checked : def.type === 'number' || def.type === 'integer' ? Number(input.value) : input.value;
    S.respond(p.id, { action: 'accept', content }); S.pending.delete(p.id); renderDock();
  } });
  const decline = h('button.btn', { text: 'Decline', onclick: () => { S.respond(p.id, { action: 'decline' }); S.pending.delete(p.id); renderDock(); } });
  card.append(h('div.prompt-actions', null, accept, decline));
  return card;
}

// ---------------------------------------------------------------- composer
const input = $('#input');
const composer = $('#composer');

function saveDraft(S) { S.draft.text = input.value; }
function loadDraft(S) {
  input.value = S.draft.text || '';
  setShell(S.draft.shell || input.value.startsWith('!'));
  renderAtts();
  autosize();
  updatePlaceholder();
}
function autosize() { input.style.height = 'auto'; input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + 'px'; }
function updatePlaceholder() {
  const S = current; if (!S) return;
  if (S.draft.shell) input.placeholder = 'Run a shell command in ' + (S.cwd.split('/').pop() || 'project') + '…';
  else if (S.suggestion && !input.value) input.placeholder = S.suggestion + '   ⇥ to accept';
  else input.placeholder = S.hasContent ? 'Reply to Claude…' : 'How can I help you today?';
}
function setShell(on) {
  if (!current) return;
  current.draft.shell = on;
  composer.classList.toggle('shell', on);
  $('#shell-badge').hidden = !on;
  updatePlaceholder();
}

function renderAtts() {
  const S = current; if (!S) return;
  $('#atts').replaceChildren(...S.draft.atts.map((a, idx) => h('div.att', { title: a.name }, h('img', { src: `data:${a.mime};base64,${a.data}` }), h('button', { text: '✕', onclick: () => { S.draft.atts.splice(idx, 1); renderAtts(); } }))));
}

function addImage(mime, data, name) {
  if (!current) return;
  current.draft.atts.push({ mime, data, name: name || 'image' });
  renderAtts();
}

function insertAtCursor(text) {
  const s = input.selectionStart, e = input.selectionEnd;
  input.value = input.value.slice(0, s) + text + input.value.slice(e);
  input.selectionStart = input.selectionEnd = s + text.length;
  autosize();
  input.focus();
}

function droppedFiles(files) {
  if (!current) return;
  for (const f of files) {
    if (f.data && f.mime) addImage(f.mime, f.data, f.name);
    else insertAtCursor('@' + rel(current, f.path) + ' ');
  }
}

input.addEventListener('input', () => {
  autosize();
  if (!current) return;
  if (input.value.startsWith('!') && !current.draft.shell) { input.value = input.value.slice(1); setShell(true); }
  current.draft.text = input.value;
  if (input.value) current.suggestion = '';
  updatePlaceholder();
  updateSendButton();
  updatePopover();
  if (input.value.startsWith('/')) warmUp(current);
});

input.addEventListener('paste', (e) => {
  const items = [...(e.clipboardData?.items || [])].filter((it) => it.kind === 'file' && it.type.startsWith('image/'));
  if (!items.length) return;
  e.preventDefault();
  for (const it of items) {
    const file = it.getAsFile();
    const r = new FileReader();
    r.onload = () => { const [, mime, data] = String(r.result).match(/^data:([^;]+);base64,(.*)$/) || []; if (data) addImage(mime, data, file.name); };
    r.readAsDataURL(file);
  }
});

input.addEventListener('keydown', (e) => {
  const S = current; if (!S) return;
  if (pop.open) {
    if (e.key === 'ArrowDown' || (e.key === 'n' && e.ctrlKey)) { e.preventDefault(); movePop(1); return; }
    if (e.key === 'ArrowUp' || (e.key === 'p' && e.ctrlKey)) { e.preventDefault(); movePop(-1); return; }
    if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) { if (pop.items.length) { e.preventDefault(); acceptPop(); return; } }
    if (e.key === 'Escape') { e.preventDefault(); closePop(); return; }
  }
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); return; }
  if (e.key === 'Tab' && e.shiftKey) { e.preventDefault(); cycleMode(); return; }
  if (e.key === 'Tab' && !input.value && S.suggestion) { e.preventDefault(); input.value = S.suggestion; S.suggestion = ''; autosize(); updatePlaceholder(); updateSendButton(); return; }
  if (e.key === 'Backspace' && !input.value && S.draft.shell) { e.preventDefault(); setShell(false); return; }
  if (e.key === 'Escape') { e.preventDefault(); if (S.draft.shell && !input.value) setShell(false); else if (S.busy) interrupt(S); return; }
  if (e.key === 'ArrowUp' && (!input.value || S.histIdx >= 0) && input.selectionStart === 0) {
    if (!S.prompts.length) return;
    e.preventDefault();
    S.histIdx = Math.min(S.histIdx + 1, S.prompts.length - 1);
    input.value = S.prompts[S.prompts.length - 1 - S.histIdx]; autosize(); updateSendButton(); return;
  }
  if (e.key === 'ArrowDown' && S.histIdx >= 0) {
    e.preventDefault();
    S.histIdx -= 1;
    input.value = S.histIdx >= 0 ? S.prompts[S.prompts.length - 1 - S.histIdx] : ''; autosize(); updateSendButton(); return;
  }
  if (e.key === 'b' && e.ctrlKey) { e.preventDefault(); if (S.live) { S.request('background_tasks'); toast('Moved running tasks to the background'); } return; }
});

$('#send').addEventListener('click', () => {
  const S = current; if (!S) return;
  if (S.busy && !input.value.trim() && !S.draft.atts.length) interrupt(S); else submit();
});
$('#attach').addEventListener('click', async () => {
  if (!current) return;
  const files = await native('pickFiles', { k: current.k });
  if (Array.isArray(files)) droppedFiles(files);
});
$('#jump').addEventListener('click', () => current && current.scroll(true));

function updateSendButton() {
  const S = current; if (!S) return;
  const btn = $('#send');
  const hasText = !!input.value.trim() || S.draft.atts.length > 0;
  const stop = S.busy && !hasText;
  btn.classList.toggle('stop', stop);
  btn.disabled = !stop && !hasText;
  btn.title = stop ? 'Stop (esc)' : S.busy ? 'Queue message (↩)' : 'Send (↩)';
}

function warmUp(S) {
  // Start the CLI as soon as the user starts typing so commands/models are ready.
  if (S.live || S.warming) return;
  S.warming = true;
  native('start', { k: S.k, opts: S.launchOpts() }).then((ok) => { if (!ok) S.warming = false; });
}

function interrupt(S) {
  if (!S.live) return;
  S.request('interrupt');
  S.verb = 'Interrupting';
}

async function submit() {
  const S = current; if (!S) return;
  closePop();
  const raw = input.value;
  const text = raw.trim();
  if (!text && !S.draft.atts.length) return;

  if (S.draft.shell) { runShell(S, text); input.value = ''; S.draft.text = ''; autosize(); return; }

  // App-level slash commands.
  const sm = text.match(/^\/(\S+)\s*([\s\S]*)$/);
  if (sm && !S.draft.atts.length) {
    const cmd = sm[1];
    if (cmd === 'clear' || cmd === 'new') { input.value = ''; S.draft.text = ''; native('newChat', { k: S.k }); return; }
    if (cmd === 'terminal') { input.value = ''; native('terminal', { k: S.k }); return; }
    if (cmd === 'activity') { input.value = ''; toggleActivity(); return; }
    if (cmd === 'resume') { input.value = ''; toast('Pick any past session in the sidebar to resume it.'); return; }
    if (cmd === 'exit' || cmd === 'quit') { input.value = ''; native('end', { k: S.k }); return; }
    if (cmd === 'model' && sm[2]) { S.opts.model = sm[2].trim(); }
    if (cmd === 'rename' && sm[2]) native('title', { k: S.k, title: sm[2].trim() });
  }

  const content = [];
  for (const a of S.draft.atts) content.push({ type: 'image', source: { type: 'base64', media_type: a.mime, data: a.data } });
  if (text) content.push({ type: 'text', text });
  const message = { type: 'user', message: { role: 'user', content: content.length === 1 && content[0].type === 'text' ? text : content }, parent_tool_use_id: null };

  const isCmd = /^\/\S/.test(text);
  const bubble = userBubble(S, text, S.draft.atts.map((a) => `data:${a.mime};base64,${a.data}`), isCmd);
  if (S.busy) bubble.querySelector('.user-bubble').classList.add('queued');
  S.append(bubble);
  S.sentQueue.push({ el: bubble.querySelector('.user-bubble'), text });
  if (text) { S.prompts.push(text); if (S.prompts.length > 200) S.prompts.shift(); store.set('hist:' + S.k, S.prompts.slice(-50)); }
  S.histIdx = -1;
  input.value = ''; S.draft.text = ''; S.draft.atts = []; S.suggestion = '';
  renderAtts(); autosize(); updatePlaceholder();
  setBusy(S, true); S.verb = 'Thinking';
  S.scroll(true);
  const ok = await S.write(message);
  if (!ok) { setBusy(S, false); bubble.append(notice('Not sent: Claude Code is not available.', 'error')); }
  if (S.title === 'New chat' && text && !isCmd) native('title', { k: S.k, title: text.slice(0, 60) });
  updateChrome();
}

async function runShell(S, cmd) {
  const card = shellCard(S, cmd);
  S.append(card.el);
  S.scroll(true);
  const res = await native('shell', { k: S.k, cmd });
  const out = res?.stdout || '', err = res?.stderr || '';
  card.done(out, err);
  S.scroll();
  // Put the command and its output into the conversation without starting a turn (like `!` in the TUI).
  const text = `<bash-input>${cmd}</bash-input>\n<bash-stdout>${out.slice(0, 30000)}</bash-stdout><bash-stderr>${err.slice(0, 10000)}</bash-stderr>`;
  S.write({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null, shouldQuery: false });
}

// ---- mode & model
function cycleMode() {
  const S = current; if (!S) return;
  const idx = CYCLE.indexOf(S.mode);
  setMode(S, CYCLE[(idx + 1) % CYCLE.length]);
}
async function setMode(S, mode) {
  const prev = S.mode;
  S.mode = mode;
  store.set('defaultMode', mode === 'bypassPermissions' ? 'default' : mode);
  updateChrome();
  if (S.live) {
    const r = await S.request('set_permission_mode', { mode });
    if (!r) { S.mode = prev; updateChrome(); }
  }
}
async function setModel(S, value) {
  S.opts.model = value;
  if (S.live) {
    const r = await S.request('set_model', { model: value });
    if (r) { S.model = value; toast('Model set to ' + modelName(S, value)); }
  } else S.model = value;
  updateChrome();
}
async function setEffort(S, level) {
  S.opts.effort = level;
  if (S.live) { const r = await S.request('apply_flag_settings', { settings: { effortLevel: level } }); if (r) toast('Effort: ' + level); }
  updateChrome();
}
function modelsFor(S) { return S.init?.models || lastModels || [{ value: 'default', displayName: 'Default' }, { value: 'opus', displayName: 'Opus' }, { value: 'sonnet', displayName: 'Sonnet' }, { value: 'haiku', displayName: 'Haiku' }]; }
function modelName(S, v) {
  if (!v) return 'Default';
  const m = modelsFor(S).find((x) => x.value === v || x.resolvedModel === v);
  if (m) return m.displayName.replace(/\s*\(recommended\)/i, '');
  return v.replace(/^claude-/, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

$('#mode').addEventListener('click', (e) => {
  const S = current; if (!S) return;
  openMenu(e.currentTarget, MODES.map((m) => ({ label: m.label, desc: m.desc, checked: S.mode === m.id, action: () => setMode(S, m.id) })), 'up');
});
$('#model').addEventListener('click', (e) => {
  const S = current; if (!S) return;
  const list = modelsFor(S);
  let curIdx = S.opts.model ? list.findIndex((m) => m.value === S.opts.model) : -1;
  if (curIdx < 0 && S.model) curIdx = list.findIndex((m) => m.value === S.model || m.resolvedModel === S.model);
  if (curIdx < 0 && !S.model) curIdx = 0;
  const items = list.map((m, idx) => ({ label: m.displayName, desc: m.description, checked: idx === curIdx, action: () => setModel(S, m.value) }));
  const curModel = modelsFor(S).find((m) => m.value === (S.opts.model || 'default')) || modelsFor(S)[0];
  const levels = curModel?.supportedEffortLevels || ['low', 'medium', 'high', 'xhigh', 'max'];
  items.push({ sep: true }, { head: 'Effort' }, { seg: levels, value: S.opts.effort, action: (lvl) => setEffort(S, lvl) });
  openMenu(e.currentTarget, items, 'up', true);
});

// ---- menus
function openMenu(anchor, items, dir, alignRight) {
  const menu = $('#menu');
  menu.replaceChildren(...items.map((it) => {
    if (it.sep) return h('div.m-sep');
    if (it.head) return h('div.m-head', { text: it.head });
    if (it.seg) return h('div.seg', null, it.seg.map((v) => h('button' + (it.value === v ? '.on' : ''), { text: v, onclick: () => { it.action(v); closeMenu(); } })));
    return h('div.m-item', { onclick: () => { closeMenu(); it.action(); } }, h('span.check', { text: it.checked ? '✓' : '' }), h('div', null, h('div.m-label', { text: it.label }), it.desc ? h('div.m-desc', { text: it.desc }) : null));
  }));
  menu.hidden = false;
  const r = anchor.getBoundingClientRect();
  const mw = menu.offsetWidth, mh = menu.offsetHeight;
  menu.style.left = Math.max(8, Math.min(alignRight ? r.right - mw : r.left, innerWidth - mw - 8)) + 'px';
  menu.style.top = (dir === 'up' ? Math.max(8, r.top - mh - 6) : r.bottom + 6) + 'px';
  setTimeout(() => document.addEventListener('mousedown', menuAway, { once: true }), 0);
}
function menuAway(e) { if (!e.target.closest('#menu')) closeMenu(); else document.addEventListener('mousedown', menuAway, { once: true }); }
function closeMenu() { $('#menu').hidden = true; }

// ---- popover: slash commands & @files
const pop = { open: false, items: [], sel: 0, kind: '', start: 0 };
let fileCache = { k: null, at: 0, list: [] };

async function updatePopover() {
  const S = current; if (!S || S.draft.shell) return closePop();
  const v = input.value, caret = input.selectionStart;
  const before = v.slice(0, caret);
  const slash = before.match(/^\/([\w:.-]*)$/);
  if (slash) {
    const q = slash[1].toLowerCase();
    const cmds = [...APP_COMMANDS, ...(S.init?.commands || [])];
    const seen = new Set();
    const items = cmds.filter((c) => { if (seen.has(c.name)) return false; seen.add(c.name); return !c.name.startsWith('__'); })
      .map((c) => ({ c, score: rank(c.name.toLowerCase(), q) }))
      .filter((x) => x.score > 0).sort((a, b) => b.score - a.score).slice(0, 60)
      .map(({ c }) => ({ label: '/' + c.name, hint: c.argumentHint || '', desc: (c.description || '').replace(/\s*\((user|project|plugin[^)]*)\)\s*$/, ''), insert: '/' + c.name + ' ' }));
    return showPop('slash', 0, items, S.init ? 'No matching commands' : 'Starting Claude Code…');
  }
  const at = before.match(/(^|\s)@([^\s@]*)$/);
  if (at) {
    const q = at[2];
    const start = caret - q.length - 1;
    if (fileCache.k !== S.k || Date.now() - fileCache.at > 30000) {
      fileCache = { k: S.k, at: Date.now(), list: (await native('files', { k: S.k })) || [] };
    }
    const ql = q.toLowerCase();
    const items = fileCache.list.map((p) => ({ p, score: q ? rank(p.toLowerCase(), ql, true) : 1 / (1 + p.length) }))
      .filter((x) => x.score > 0).sort((a, b) => b.score - a.score).slice(0, 50)
      .map(({ p }) => ({ label: p, insert: '@' + p + (p.endsWith('/') ? '' : ' '), desc: '' }));
    return showPop('file', start, items, 'No matching files');
  }
  closePop();
}
function rank(s, q, path) {
  if (!q) return 1;
  if (s === q) return 1000;
  if (s.startsWith(q)) return 500 - s.length;
  const base = path ? s.split('/').pop() : s;
  if (base.startsWith(q)) return 400 - s.length;
  if (s.includes(q)) return 200 - s.indexOf(q) - s.length / 10;
  let i = 0; for (const ch of s) { if (ch === q[i]) i++; if (i === q.length) return 50 - s.length / 10; }
  return 0;
}
function showPop(kind, start, items, empty) {
  pop.open = true; pop.kind = kind; pop.items = items; pop.sel = 0; pop.start = start;
  const el = $('#popover');
  el.hidden = false;
  if (!items.length) { el.replaceChildren(h('div.pop-empty', { text: empty })); return; }
  el.replaceChildren(...items.map((it, idx) => h('div.pop-item' + (idx === 0 ? '.sel' : ''), { onmousedown: (e) => { e.preventDefault(); pop.sel = idx; acceptPop(); } }, h('span.name', { text: it.label }), it.hint ? h('span.hint', { text: it.hint }) : null, h('span.desc', { text: it.desc || '' }))));
}
function movePop(d) {
  if (!pop.items.length) return;
  pop.sel = (pop.sel + d + pop.items.length) % pop.items.length;
  const kids = $('#popover').children;
  [...kids].forEach((k, i) => k.classList.toggle('sel', i === pop.sel));
  kids[pop.sel]?.scrollIntoView({ block: 'nearest' });
}
function acceptPop() {
  const it = pop.items[pop.sel]; if (!it) return;
  if (pop.kind === 'slash') { input.value = it.insert; input.selectionStart = input.selectionEnd = input.value.length; }
  else { const caret = input.selectionStart; input.value = input.value.slice(0, pop.start) + it.insert + input.value.slice(caret); input.selectionStart = input.selectionEnd = pop.start + it.insert.length; }
  if (current) current.draft.text = input.value;
  closePop(); autosize(); updateSendButton();
  if (it.insert.endsWith('/')) updatePopover();
}
function closePop() { pop.open = false; pop.items = []; $('#popover').hidden = true; }
input.addEventListener('blur', () => setTimeout(closePop, 150));
input.addEventListener('click', updatePopover);

// ---------------------------------------------------------------- chrome: status line, working indicator
function updateChrome() {
  const S = current; if (!S) return;
  const mode = MODES.find((m) => m.id === S.mode) || MODES[0];
  const modeBtn = $('#mode');
  modeBtn.dataset.mode = S.mode;
  modeBtn.replaceChildren(h('span.chip-dot'), mode.label);
  const effort = S.opts.effort ? ` · ${S.opts.effort}` : '';
  $('#model').textContent = modelName(S, S.opts.model || S.model) + effort + '  ▾';
  updateSendButton();
  updatePlaceholder();

  const left = h('div.left');
  left.append(h('span.clickable', { text: S.cwd.replace(config.home, '~'), title: 'Reveal in Finder', onclick: () => native('openPath', { k: S.k, path: S.cwd, reveal: true }) }));
  if (!S.live && S.resumable) left.append(h('span', { text: 'resumes on send' }));
  else if (S.live) left.append(h('span', { text: '● live', style: 'color:var(--ok)' }));
  const running = [...S.tasks.values()].filter((t) => t.status === 'running').length;
  if (running) left.append(h('span.clickable', { text: `${running} task${running > 1 ? 's' : ''} running`, onclick: toggleActivity }));
  const right = h('div.right');
  if (S.usageText) right.append(h('span', { text: S.usageText.replace(/\s+/g, ' ') }));
  if (S.ctx?.percentage != null) {
    const pct = Math.round(S.ctx.percentage);
    right.append(h('span.clickable', { title: `${fmtTok(S.ctx.totalTokens)} / ${fmtTok(S.ctx.maxTokens)} tokens`, onclick: toggleActivity }, h('span.ctx-bar' + (pct > 85 ? '.crit' : pct > 65 ? '.hot' : ''), null, h('i', { style: `width:${Math.min(100, pct)}%` })), `${pct}% context`));
  }
  $('#status').replaceChildren(left, right);
}

setInterval(() => {
  for (const S of sessions.values()) {
    if (!S.busy) continue;
    const secs = Math.round((Date.now() - S.turnStart) / 1000);
    const tok = S.thinkTok + S.outTok;
    S.working.querySelector('.verb').textContent = S.verb + '…';
    S.working.querySelector('.meta').textContent = `${secs}s${tok ? ' · ↓ ' + fmtTok(tok) + ' tokens' : ''} · esc to interrupt`;
    for (const t of S.tools.values()) if (t.status === 'running' && !t.agent && t.metaEl && !t.elapsed) t.metaEl.textContent = Math.round((Date.now() - t.start) / 1000) + 's';
  }
  if (activityOpen()) renderActivity();
}, 1000);

// ---------------------------------------------------------------- activity panel
const activityOpen = () => !$('#activity').hidden;
function toggleActivity() { $('#activity').hidden = !$('#activity').hidden; store.set('activity', activityOpen()); renderActivity(); if (activityOpen() && current?.live) current.request('get_context_usage').then((r) => { if (r) { current.ctx = r; renderActivity(); updateChrome(); } }); }
$('#activity-close').addEventListener('click', toggleActivity);
let actTimer = 0;
function scheduleActivity() { if (!activityOpen() || actTimer) return; actTimer = setTimeout(() => { actTimer = 0; renderActivity(); }, 250); }

function renderActivity() {
  if (!activityOpen()) return;
  const body = $('#activity-body');
  const S = current;
  if (!S) { body.replaceChildren(h('div.a-empty', { text: 'No session selected.' })); return; }
  const kids = [];

  const runningTools = [...S.tools.values()].filter((t) => !t.agent && (t.status === 'running' || t.status === 'pending'));
  kids.push(h('div.a-sec', null, h('span', { text: 'Running now' }), S.busy && S.live ? h('button.mini-btn', { text: 'Stop turn', onclick: () => interrupt(S) }) : null));
  if (!runningTools.length) kids.push(h('div.a-empty', { text: S.busy ? 'Thinking…' : 'Nothing running.' }));
  for (const t of runningTools) {
    const sum = toolSummary(t);
    const secs = t.elapsed ? Math.round(t.elapsed) : Math.round((Date.now() - t.start) / 1000);
    kids.push(h('div.a-item', { onclick: () => revealEl(t.el) }, t.status === 'pending' ? h('span.dot', { style: 'background:var(--warn)' }) : h('span.spin'), h('div.a-main', null, h('div.a-title', { text: toolLabel(t.name) + (t.parent ? '  (subagent)' : '') }), h('div.a-sub', { text: sum.title || sum.text })), h('span.tool-meta', { text: secs + 's' })));
  }

  const tasks = [...S.tasks.values()].filter((t) => !t.skip).sort((a, b) => (a.status === 'running' ? 0 : 1) - (b.status === 'running' ? 0 : 1) || (b.start || 0) - (a.start || 0));
  kids.push(h('div.a-sec', null, h('span', { text: 'Subagents & background tasks' }), S.live && S.busy ? h('button.mini-btn', { text: 'Background all ⌃B', onclick: () => S.request('background_tasks') }) : null));
  if (!tasks.length) kids.push(h('div.a-empty', { text: 'None yet.' }));
  for (const t of tasks.slice(0, 30)) {
    const running = t.status === 'running';
    const kind = t.type === 'local_agent' || t.subagent ? (t.subagent || 'agent') : t.type === 'local_bash' ? 'shell' : t.type === 'local_workflow' ? 'workflow' : (t.type || 'task');
    const stats = [t.usage?.tool_uses != null ? `${t.usage.tool_uses} tools` : '', t.usage?.total_tokens ? fmtTok(t.usage.total_tokens) + ' tok' : '', fmtDur(t.usage?.duration_ms ?? ((t.end || Date.now()) - (t.start || Date.now())))].filter(Boolean).join(' · ');
    const target = t.toolId ? (S.agents.get(t.toolId)?.el || S.tools.get(t.toolId)?.el) : null;
    kids.push(h('div.a-item', { onclick: () => target && revealEl(target) },
      running ? h('span.spin') : h('span', { text: t.status === 'completed' ? '✓' : t.status === 'failed' ? '✕' : '■', style: `color:var(--${t.status === 'completed' ? 'ok' : 'err'})` }),
      h('div.a-main', null, h('div.a-title', null, h('span.badge', { text: kind }), ' ', t.desc || t.id), h('div.a-sub', { text: running ? (t.last || stats) : (t.summary || stats || t.status).split('\n')[0] })),
      running && S.live ? h('button.mini-btn', { text: 'Stop', onclick: (e) => { e.stopPropagation(); S.request('stop_task', { task_id: t.id }); } }) : null,
      !running && t.output ? h('button.mini-btn', { text: 'Output', onclick: (e) => { e.stopPropagation(); native('openPath', { k: S.k, path: t.output }); } }) : null));
  }

  kids.push(h('div.a-sec', null, h('span', { text: 'Context' }), S.live ? h('button.mini-btn', { text: 'Refresh', onclick: () => S.request('get_context_usage').then((r) => { if (r) { S.ctx = r; renderActivity(); updateChrome(); } }) }) : null));
  if (S.ctx) {
    kids.push(h('div.big-bar', null, h('i', { style: `width:${Math.min(100, S.ctx.percentage || 0)}%` })));
    kids.push(h('div.ctx-cats', null, h('div.row', null, h('strong', { text: `${fmtTok(S.ctx.totalTokens)} / ${fmtTok(S.ctx.maxTokens)}` }), h('span', { text: Math.round(S.ctx.percentage) + '%' })),
      (S.ctx.categories || []).filter((c) => c.tokens > 0).map((c) => h('div.row', null, h('span', { text: c.name }), h('span', { text: fmtTok(c.tokens) })))));
    kids.push(h('div', { style: 'padding:4px 8px' }, h('button.mini-btn', { text: 'Compact now', onclick: () => { input.value = '/compact'; submit(); } })));
  } else kids.push(h('div.a-empty', { text: S.live ? 'Updates after each turn.' : 'Available once the session is running.' }));

  kids.push(h('div.a-sec', { text: 'Session' }));
  const acct = S.init?.account;
  const kv = [
    ['Model', modelName(S, S.opts.model || S.model)],
    ['Mode', (MODES.find((m) => m.id === S.mode) || {}).label],
    ['Session', S.sys?.session_id || S.k],
    ['Folder', S.cwd.replace(config.home, '~')],
    ['Version', S.init?.claude_code_version || S.sys?.claude_code_version || ''],
    ['Account', acct ? `${acct.subscriptionType || ''} ${acct.organization ? '· ' + acct.organization : ''}`.trim() : ''],
    ['Cost', S.cost ? '$' + S.cost.toFixed(4) : ''],
  ].filter(([, v]) => v);
  kids.push(h('dl.a-kv', null, kv.flatMap(([k, v]) => [h('dt', { text: k }), h('dd', { text: v, title: v, onclick: k === 'Session' ? () => { native('copy', { text: v }); toast('Session id copied'); } : null })])));
  const mcps = S.sys?.mcp_servers || [];
  if (mcps.length) {
    kids.push(h('div.a-sec', { text: `MCP servers (${mcps.length})` }));
    for (const m of mcps) kids.push(h('div.a-item', { style: 'cursor:default' }, h('span.mcp-dot.' + (m.status || '').replace(/\s/g, '-')), h('div.a-main', null, h('div.a-title', { text: m.name.replace(/^claude\.ai /, '') }), h('div.a-sub', { text: m.status })), m.status === 'failed' || m.status === 'needs-auth' ? h('button.mini-btn', { text: 'Reconnect', onclick: () => S.request('mcp_reconnect', { serverName: m.name }).then(() => toast('Reconnecting ' + m.name)) }) : null));
  }
  kids.push(h('div.a-sec', { text: 'Actions' }));
  kids.push(h('div', { style: 'display:flex;gap:6px;flex-wrap:wrap;padding:2px 6px' },
    h('button.btn', { text: 'Open in Terminal', onclick: () => native('terminal', { k: S.k }) }),
    h('button.btn', { text: 'New chat', onclick: () => native('newChat', { k: S.k }) }),
    S.live ? h('button.btn.danger', { text: 'End process', onclick: () => native('end', { k: S.k }) }) : null));
  body.replaceChildren(...kids);
}

function revealEl(el) {
  if (!el) return;
  let p = el.parentElement;
  while (p) { if (p.classList?.contains('agent-body') && p.hidden) { const a = p.closest('.agent'); a?.querySelector('.agent-head')?.click(); } p = p.parentElement; }
  el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  el.animate([{ background: 'var(--accent-soft)' }, { background: 'transparent' }], { duration: 1200 });
}

// ---------------------------------------------------------------- global handlers
document.addEventListener('click', (e) => {
  const copy = e.target.closest('.copy-code');
  if (copy) {
    const block = copy.closest('.code-block');
    const text = block.dataset.raw || block.querySelector('pre').innerText;
    native('copy', { text }); copy.textContent = 'Copied'; setTimeout(() => (copy.textContent = 'Copy'), 1200);
    return;
  }
  const a = e.target.closest('a[href]');
  if (a) {
    e.preventDefault();
    const href = a.getAttribute('href');
    if (/^(https?|mailto):/i.test(href)) native('openURL', { url: href });
    else if (href && !href.startsWith('#')) native('openPath', { k: current?.k, path: decodeURI(href.replace(/^file:\/\//, '')).replace(/#L?\d+.*$/, '') });
    return;
  }
  const pl = e.target.closest('code.path-link');
  if (pl && current) { native('openPath', { k: current.k, path: pl.dataset.path.replace(/:\d+(-\d+)?$/, '') }); return; }
  const img = e.target.closest('.prose img');
  if (img) lightbox(img.src);
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && current) {
    if (!$('#menu').hidden) { closeMenu(); return; }
    const card = $('#dock .prompt-card');
    if (card && document.activeElement !== input) return;
    if (current.busy && document.activeElement !== input) interrupt(current);
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 'f') return;
  // Typing anywhere focuses the composer.
  if (current && !e.metaKey && !e.ctrlKey && !e.altKey && e.key.length === 1 && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName)) input.focus();
});

let dragDepth = 0, dropHint = null;
document.addEventListener('dragenter', (e) => { if (!current) return; dragDepth++; if (!dropHint) { dropHint = h('div.drop-hint', { text: 'Drop files to attach' }); document.body.append(dropHint); } });
document.addEventListener('dragleave', () => { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth && dropHint) { dropHint.remove(); dropHint = null; } });
document.addEventListener('drop', () => { dragDepth = 0; if (dropHint) { dropHint.remove(); dropHint = null; } });
document.addEventListener('dragover', (e) => e.preventDefault());

function appCommand(name) {
  if (name === 'interrupt' && current) interrupt(current);
  if (name === 'toggleActivity') toggleActivity();
  if (name === 'focus') input.focus();
}

if (store.get('activity', false)) $('#activity').hidden = false;
native('ready');
