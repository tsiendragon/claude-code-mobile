"use strict";

/**
 * ccm Bridge Web Console — a vanilla WebSocket client that speaks the same
 * protocol as the Flutter app. Built as a manual/agent test surface for the Bridge.
 */

const PROTOCOL_VERSION = 1;
const RPC_TIMEOUT_MS = 30000;
const LS_URL = "ccm.ws_url";
const LS_TOKEN = "ccm.token";
const LS_RUN_BACKEND = "ccm.run_backend";
const LS_RUN_WORKSPACE = "ccm.run_workspace";

const $ = (sel) => document.querySelector(sel);
const el = (id) => document.getElementById(id);

const state = {
  ws: null,
  url: "",
  token: "",
  connected: false,
  reconnectAttempts: 0,
  manualClose: false,
  reqSeq: 0,
  pending: new Map(), // id -> {resolve, reject, timer, type}
  sessions: new Map(), // session_id -> summary
  workspaces: [],
  active: null, // session_id
  chat: null, // {items:[], lastSeq, byClientId:Map, pendingApproval, hasMore, nextBefore}
  uploads: [] // {path, name}
};

/* ---------------- utilities ---------------- */

function genReqId() {
  state.reqSeq += 1;
  return `req_${Date.now().toString(36)}_${state.reqSeq}`;
}

function genClientMsgId() {
  const rand = Math.random().toString(36).slice(2, 12);
  return `cmsg_${rand}`;
}

function toast(message, isError) {
  const node = el("toast");
  node.textContent = message;
  node.classList.toggle("toast-error", Boolean(isError));
  node.hidden = false;
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => { node.hidden = true; }, 4000);
}

function escapeHtml(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function stripAnsi(text) {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g, "");
}

function formatAssistantText(input) {
  const lines = stripAnsi(input).replace(/\r/g, "").split("\n");
  const out = [];
  for (const raw of lines) {
    const trimmed = raw.replace(/ /g, " ").trimEnd();
    const left = trimmed.trimStart();
    if (left.startsWith("✻")) continue;
    if (left.startsWith("●")) {
      out.push(left.replace(/^●\s*/, "").trimEnd());
    } else {
      out.push(trimmed.replace(/^\s{0,2}/, ""));
    }
  }
  while (out.length && !out[0].trim()) out.shift();
  while (out.length && !out[out.length - 1].trim()) out.pop();
  return out.join("\n").replace(/\n{3,}/g, "\n\n");
}

/** Minimal markdown -> HTML: fenced code, inline code; everything else escaped. */
function renderMarkdown(text) {
  const parts = text.split(/```/);
  let html = "";
  for (let i = 0; i < parts.length; i += 1) {
    if (i % 2 === 1) {
      const body = parts[i].replace(/^[a-zA-Z0-9]*\n/, "");
      html += `<pre><code>${escapeHtml(body)}</code></pre>`;
    } else {
      html += escapeHtml(parts[i])
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\n/g, "<br>");
    }
  }
  return html;
}

/* ---------------- RPC / WebSocket ---------------- */

function defaultWsUrl() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${location.host}/ws`;
}

function setConn(status, text) {
  state.connected = status === "on";
  const dot = el("conn-dot");
  dot.className = `dot dot-${status}`;
  el("conn-text").textContent = text;
  el("btn-disconnect").hidden = status === "off";
}

function logLine(kind, label, payload) {
  const log = el("event-log");
  const line = document.createElement("div");
  line.className = `log-line log-${kind}`;
  const body = typeof payload === "string" ? payload : JSON.stringify(payload);
  line.textContent = `${new Date().toLocaleTimeString()} ${label} ${body}`;
  log.appendChild(line);
  while (log.childElementCount > 500) log.removeChild(log.firstChild);
  log.scrollTop = log.scrollHeight;
}

function connect(url, token) {
  state.url = url;
  state.token = token;
  state.manualClose = false;
  setConn("connecting", "connecting…");

  let ws;
  try {
    ws = new WebSocket(url);
  } catch (error) {
    setConn("error", "bad url");
    showAuthError(String(error));
    return;
  }
  state.ws = ws;

  ws.onopen = () => {
    logLine("out", "open", url);
    rpc("auth", { token, protocol_version: PROTOCOL_VERSION })
      .then(() => {
        state.reconnectAttempts = 0;
        setConn("on", "connected");
        persistCredentials();
        onAuthenticated();
      })
      .catch((error) => {
        setConn("error", "auth failed");
        showAuthError(error.message || "auth failed");
      });
  };

  ws.onmessage = (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      logLine("err", "parse", event.data);
      return;
    }
    if (message.type === "response") {
      handleResponse(message);
    } else if (message.type === "event") {
      handleEvent(message);
    }
  };

  ws.onclose = (event) => {
    logLine("err", "close", `${event.code} ${event.reason}`);
    rejectAllPending(`socket closed (${event.code})`);
    if (state.manualClose) {
      setConn("off", "disconnected");
      return;
    }
    setConn("error", `closed: ${event.reason || event.code}`);
    scheduleReconnect();
  };

  ws.onerror = () => { logLine("err", "error", "socket error"); };
}

function scheduleReconnect() {
  if (state.manualClose || !state.token) return;
  state.reconnectAttempts += 1;
  if (state.reconnectAttempts > 10) {
    setConn("error", "giving up — reconnect manually");
    return;
  }
  const delay = Math.min(1000 * 2 ** state.reconnectAttempts, 15000);
  setConn("connecting", `reconnecting in ${Math.round(delay / 1000)}s…`);
  clearTimeout(scheduleReconnect._t);
  scheduleReconnect._t = setTimeout(() => connect(state.url, state.token), delay);
}

function disconnect() {
  state.manualClose = true;
  if (state.ws) state.ws.close(1000, "client disconnect");
  state.ws = null;
}

function rpc(type, params = {}) {
  return new Promise((resolve, reject) => {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
      reject(new Error("not connected"));
      return;
    }
    const id = genReqId();
    const envelope = { type, id, ...params };
    const timer = setTimeout(() => {
      state.pending.delete(id);
      reject(new Error(`${type} timed out`));
    }, RPC_TIMEOUT_MS);
    state.pending.set(id, { resolve, reject, timer, type });
    state.ws.send(JSON.stringify(envelope));
    if (type !== "auth") logLine("out", `→ ${type}`, params);
    else logLine("out", "→ auth", "{token: ***}");
  });
}

function handleResponse(message) {
  const entry = state.pending.get(message.id);
  if (!entry) return;
  clearTimeout(entry.timer);
  state.pending.delete(message.id);
  if (message.ok) {
    logLine("in", `← ${entry.type}`, message.data);
    entry.resolve(message.data);
  } else {
    logLine("err", `← ${entry.type} ERR`, message.error);
    const error = new Error(message.error?.message || "request failed");
    error.code = message.error?.code;
    error.retryable = message.error?.retryable;
    entry.reject(error);
  }
}

function rejectAllPending(reason) {
  for (const [, entry] of state.pending) {
    clearTimeout(entry.timer);
    entry.reject(new Error(reason));
  }
  state.pending.clear();
}

/* ---------------- Auth panel ---------------- */

function showAuthError(message) {
  const node = el("auth-error");
  node.textContent = message;
  node.hidden = false;
}

function persistCredentials() {
  if (el("remember").checked) {
    localStorage.setItem(LS_URL, state.url);
    localStorage.setItem(LS_TOKEN, state.token);
  }
}

function persistRunDefaults(params) {
  if (params.backend) localStorage.setItem(LS_RUN_BACKEND, params.backend);
  if (params.workspace_id) localStorage.setItem(LS_RUN_WORKSPACE, params.workspace_id);
}

async function onAuthenticated() {
  el("auth-panel").hidden = true;
  el("workspace").hidden = false;
  el("auth-error").hidden = true;
  await Promise.all([refreshSessions(), refreshWorkspaces(), refreshStats()]);
  // If we were viewing a session, recover its event stream.
  if (state.active) {
    await attachSession(state.active, { recover: true });
  }
}

/* ---------------- Sessions ---------------- */

async function refreshSessions() {
  try {
    const data = await rpc("session.list");
    state.sessions.clear();
    for (const summary of data.sessions || []) {
      state.sessions.set(summary.session_id, summary);
    }
    renderSessionList();
  } catch (error) {
    toast(`session.list: ${error.message}`, true);
  }
}

async function refreshWorkspaces() {
  try {
    const data = await rpc("workspace.list");
    state.workspaces = data.workspaces || [];
    const select = el("run-workspace");
    select.innerHTML = "";
    for (const ws of state.workspaces) {
      const opt = document.createElement("option");
      opt.value = ws.id || ws.workspace_id || "";
      opt.textContent = ws.name || opt.value;
      select.appendChild(opt);
    }
    applyRunDefaults();
    updateQuickRun();
  } catch (error) {
    toast(`workspace.list: ${error.message}`, true);
  }
}

function applyRunDefaults() {
  const backend = localStorage.getItem(LS_RUN_BACKEND);
  if (backend && [...el("run-backend").options].some((opt) => opt.value === backend)) {
    el("run-backend").value = backend;
  }

  const workspace = localStorage.getItem(LS_RUN_WORKSPACE);
  if (workspace && [...el("run-workspace").options].some((opt) => opt.value === workspace)) {
    el("run-target").value = "workspace";
    el("run-workspace").value = workspace;
    el("workspace-field").hidden = false;
    el("cwd-field").hidden = true;
  }
}

function updateQuickRun() {
  const button = el("btn-quick-run");
  const workspaceId = preferredWorkspaceId();
  const workspace = workspaceById(workspaceId);
  button.disabled = !workspace;
  button.textContent = workspace ? `Start ${workspace.name || workspaceId}` : "Start last workspace";
}

function renderSessionList() {
  const list = el("session-list");
  list.innerHTML = "";
  const summaries = [...state.sessions.values()];
  if (summaries.length === 0) {
    const li = document.createElement("li");
    li.className = "session-item";
    li.innerHTML = `<span class="muted">No sessions yet.</span>`;
    list.appendChild(li);
    return;
  }
  for (const summary of summaries) {
    const li = document.createElement("li");
    li.className = "session-item" + (summary.session_id === state.active ? " active" : "");
    li.dataset.testid = `session-${summary.session_id}`;
    const attn = summary.needs_attention ? `<span class="attn">●</span> ` : "";
    li.innerHTML = `
      <div class="row">
        <span class="name">${attn}${escapeHtml(summary.name)}</span>
        <span class="badge ${summary.state}">${summary.state}</span>
      </div>
      <div class="cwd">${escapeHtml(summary.cwd || "")}</div>`;
    li.onclick = () => attachSession(summary.session_id);
    list.appendChild(li);
  }
}

async function runSession(event) {
  event.preventDefault();
  const params = {
    backend: el("run-backend").value,
    skip_permissions: el("run-skip").checked
  };
  if (el("run-target").value === "workspace") {
    params.workspace_id = el("run-workspace").value;
    if (!params.workspace_id) { toast("pick or create a workspace", true); return; }
  } else {
    params.cwd = el("run-cwd").value.trim();
    if (!params.cwd) { toast("cwd is required", true); return; }
  }
  params.name = resolvedRunName(params);
  await startSession(params, { clearName: true });
}

async function quickRunSession() {
  const workspaceId = preferredWorkspaceId();
  const workspace = workspaceById(workspaceId);
  if (!workspace) { toast("pick a workspace once first", true); return; }
  const params = {
    name: workspace.name || "Session",
    backend: localStorage.getItem(LS_RUN_BACKEND) || el("run-backend").value,
    workspace_id: workspaceId,
    skip_permissions: false
  };
  await startSession(params);
}

async function startSession(params, opts = {}) {
  try {
    const data = await rpc("session.run", params);
    persistRunDefaults(params);
    updateQuickRun();
    toast(`Started ${data.name || params.name}`);
    await refreshSessions();
    await attachSession(data.session_id);
    if (opts.clearName) el("run-name").value = "";
  } catch (error) {
    toast(`session.run: ${error.message}`, true);
  }
}

function preferredWorkspaceId() {
  const saved = localStorage.getItem(LS_RUN_WORKSPACE);
  if (saved && workspaceById(saved)) return saved;
  return el("run-workspace").value || state.workspaces[0]?.id || state.workspaces[0]?.workspace_id;
}

function workspaceById(id) {
  if (!id) return null;
  return state.workspaces.find((ws) => (ws.id || ws.workspace_id) === id) || null;
}

function resolvedRunName(params) {
  const explicit = el("run-name").value.trim();
  if (explicit) return explicit;
  if (params.workspace_id) {
    const workspace = workspaceById(params.workspace_id);
    return workspace?.name || params.workspace_id || "Session";
  }
  const cwd = params.cwd || "";
  const parts = cwd.split("/").filter(Boolean);
  return parts.at(-1) || "Session";
}

async function createWorkspace() {
  const name = prompt("New workspace name:");
  if (!name) return;
  try {
    const data = await rpc("workspace.create", { name });
    await refreshWorkspaces();
    const id = data.workspace?.id || data.workspace?.workspace_id;
    if (id) el("run-workspace").value = id;
    toast("Workspace created");
  } catch (error) {
    toast(`workspace.create: ${error.message}`, true);
  }
}

/* ---------------- Chat ---------------- */

async function attachSession(sessionId, opts = {}) {
  try {
    showMobilePanel("chat");
    const data = await rpc("session.attach", { session_id: sessionId });
    state.active = sessionId;
    const session = normalizeSessionRecord(data.session);
    if (session) state.sessions.set(sessionId, session);

    state.chat = {
      items: [],
      lastSeq: data.last_seq || 0,
      byClientId: new Map(),
      pendingApproval: data.pending_approval || null,
      hasMore: Boolean(data.history?.has_more),
      nextBefore: data.history?.next_before ?? null
    };

    // History transcript items first, then recent live events.
    for (const item of data.items || []) addItemFromTranscript(item);
    for (const ev of data.recent_events || []) applyEventToChat(ev, true);

    renderChatHeader();
    renderMessages();
    renderApproval();
    renderSessionList();
    el("history-bar").hidden = !state.chat.hasMore;
    refreshFiles();
    if (data.has_event_gap) toast("Event gap detected — history may be incomplete", true);
  } catch (error) {
    toast(`session.attach: ${error.message}`, true);
  }
}

function normalizeSessionRecord(raw) {
  if (!raw) return null;
  return {
    session_id: raw.session_id || raw.sessionId,
    name: raw.name,
    backend: raw.backend,
    cwd: raw.cwd,
    state: raw.state,
    last_seq: raw.last_seq ?? raw.lastSeq ?? 0,
    needs_attention: raw.state === "approval" || raw.state === "choosing"
  };
}

function activeSummary() {
  return state.sessions.get(state.active);
}

function renderChatHeader() {
  const summary = activeSummary();
  if (!summary) return;
  el("chat-title").textContent = summary.name;
  el("chat-meta").textContent = `${summary.backend} · ${summary.cwd || ""}`;
  renderStateBadge(summary.state);
  updateComposerEnabled(summary.state);
}

function renderStateBadge(stateName) {
  const badge = el("state-badge");
  badge.textContent = stateName || "";
  badge.className = `badge ${stateName || ""}`;
}

function updateComposerEnabled(stateName) {
  const active = Boolean(state.active);
  const ended = stateName === "ended";
  el("prompt").disabled = !active || ended;
  el("btn-send").disabled = !active || ended;
  el("btn-attach").disabled = !active || ended;
  el("btn-interrupt").disabled = !active || !(stateName === "thinking");
  el("btn-kill").disabled = !active || ended;
  document.querySelectorAll("#prompt-shortcuts button").forEach((button) => {
    button.disabled = !active || ended;
  });
}

function addItemFromTranscript(item) {
  const role = item.role || "assistant";
  const rawText = item.text || item.content || "";
  if (!rawText.trim()) return;
  state.chat.items.push({
    id: item.id || item.message_id || `msg_${item.message_seq || item.seq || state.chat.items.length}`,
    role,
    text: role === "assistant" ? formatAssistantText(rawText) : rawText,
    seq: item.seq ?? item.message_seq ?? null,
    snapshot: Boolean(item.snapshot)
  });
}

function applyEventToChat(envelope, fromSnapshot) {
  const ev = envelope.event || {};
  const seq = envelope.seq || 0;
  if (seq > state.chat.lastSeq) state.chat.lastSeq = seq;

  switch (ev.kind) {
    case "user_message": {
      const clientId = ev.clientMsgId || ev.client_msg_id;
      if (clientId && state.chat.byClientId.has(clientId)) {
        const existing = state.chat.byClientId.get(clientId);
        existing.pending = false;
        existing.seq = seq;
        break;
      }
      if (!ev.text) break;
      const item = { id: clientId || `evt_${seq}`, role: "user", text: ev.text, seq };
      if (clientId) state.chat.byClientId.set(clientId, item);
      state.chat.items.push(item);
      break;
    }
    case "assistant_message": {
      if (!ev.text) break;
      const id = ev.messageId || ev.message_id || `evt_${seq}`;
      const existingIdx = state.chat.items.findIndex((m) => m.id === id);
      const text = formatAssistantText(ev.text);
      if (existingIdx >= 0) {
        state.chat.items[existingIdx].text = text;
      } else {
        state.chat.items.push({ id, role: "assistant", text, seq, snapshot: Boolean(ev.snapshot) });
      }
      break;
    }
    case "message_delivered": {
      const clientId = ev.clientMsgId || ev.client_msg_id;
      const item = clientId && state.chat.byClientId.get(clientId);
      if (item) item.pending = false;
      break;
    }
    case "message_failed": {
      const clientId = ev.clientMsgId || ev.client_msg_id;
      const item = clientId && state.chat.byClientId.get(clientId);
      if (item) { item.pending = false; item.failed = true; }
      if (!fromSnapshot) toast(`message failed: ${ev.message || ev.code}`, true);
      break;
    }
    case "state_changed": {
      const summary = activeSummary();
      if (summary) { summary.state = ev.state; summary.needs_attention = ev.state === "approval" || ev.state === "choosing"; }
      if (!fromSnapshot) { renderStateBadge(ev.state); updateComposerEnabled(ev.state); }
      break;
    }
    case "approval_requested": {
      state.chat.pendingApproval = ev.approval;
      if (!fromSnapshot) renderApproval();
      break;
    }
    case "approval_resolved": {
      if (state.chat.pendingApproval && state.chat.pendingApproval.approvalId === ev.approvalId) {
        state.chat.pendingApproval = null;
        if (!fromSnapshot) renderApproval();
      }
      break;
    }
    case "session_ended": {
      const summary = activeSummary();
      if (summary) summary.state = "ended";
      if (!fromSnapshot) { renderStateBadge("ended"); updateComposerEnabled("ended"); }
      break;
    }
    default:
      break;
  }
}

function renderMessages() {
  const container = el("messages");
  const wasAtBottom = container.scrollHeight - container.scrollTop < 120;
  container.innerHTML = "";
  if (state.chat.items.length === 0) {
    container.innerHTML = `<p class="placeholder">No messages yet.</p>`;
    return;
  }
  for (const item of state.chat.items) {
    container.appendChild(renderMessage(item));
  }
  if (wasAtBottom) container.scrollTop = container.scrollHeight;
}

function renderMessage(item) {
  const div = document.createElement("div");
  div.className = `msg msg-${item.role}` + (item.pending ? " pending" : "") + (item.failed ? " failed" : "");
  div.dataset.testid = `msg-${item.role}`;
  if (item.role === "assistant") {
    div.innerHTML = renderMarkdown(item.text);
    if (item.seq != null) div.appendChild(buildFeedbackBar(item));
  } else {
    div.textContent = item.text;
  }
  if (item.failed) {
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = "failed to deliver";
    div.appendChild(meta);
  }
  return div;
}

function buildFeedbackBar(item) {
  const bar = document.createElement("div");
  bar.className = "feedback";
  const good = document.createElement("button");
  good.className = "btn btn-ghost";
  good.textContent = "👍";
  good.title = "good";
  good.onclick = () => submitFeedback(item, "good");
  const bad = document.createElement("button");
  bad.className = "btn btn-ghost";
  bad.textContent = "👎";
  bad.title = "report bad output";
  bad.onclick = () => reportBad(item);
  bar.appendChild(good);
  bar.appendChild(bad);
  return bar;
}

async function submitFeedback(item, verdict, note) {
  if (item.seq == null) { toast("no message_seq to attach feedback to", true); return; }
  try {
    await rpc("feedback.submit", {
      session_id: state.active,
      message_seq: item.seq,
      message_id: typeof item.id === "string" ? item.id : undefined,
      verdict,
      note,
      client: { app_version: "web-console", platform: "web" }
    });
    toast("Feedback submitted");
  } catch (error) {
    toast(`feedback.submit: ${error.message}`, true);
  }
}

function reportBad(item) {
  const verdict = prompt(
    "Verdict (format_error, wrong_role, missing_content, garbled, choice_misparse, render_issue, other):",
    "other"
  );
  if (!verdict) return;
  const note = prompt("Optional note:") || undefined;
  submitFeedback(item, verdict, note);
}

/* ---------------- Approvals ---------------- */

function renderApproval() {
  const area = el("approval-area");
  area.innerHTML = "";
  const approval = state.chat && state.chat.pendingApproval;
  if (!approval) return;

  const card = document.createElement("div");
  card.className = "approval-card";
  card.dataset.testid = "approval-card";
  const paths = (approval.paths || []).map(escapeHtml).join("<br>");
  card.innerHTML = `
    <h4>Approval needed · ${escapeHtml(approval.operationKind || "unknown")}</h4>
    <div class="desc">${escapeHtml(approval.description || "")}</div>
    ${paths ? `<div class="paths">${paths}</div>` : ""}
    ${approval.diffSummary ? `<pre>${escapeHtml(approval.diffSummary)}</pre>` : ""}
    ${approval.expiresAt ? `<div class="expires">expires ${escapeHtml(approval.expiresAt)}</div>` : ""}`;

  const actions = document.createElement("div");
  actions.className = "actions";
  const choices = approval.choices || [];
  if (choices.length > 0) {
    for (const choice of choices) {
      const btn = document.createElement("button");
      btn.className = "btn btn-primary";
      btn.textContent = choice.label || choice.value;
      btn.onclick = () => sendApproval(approval.approvalId, "choice", choice.value);
      actions.appendChild(btn);
    }
  }
  for (const action of approval.actions || []) {
    if (action === "choice") continue;
    const btn = document.createElement("button");
    btn.className = "btn " + (action === "no" || action === "reject" ? "btn-danger" : "btn-primary");
    btn.textContent = action;
    btn.dataset.testid = `approval-${action}`;
    btn.onclick = () => sendApproval(approval.approvalId, action);
    actions.appendChild(btn);
  }
  card.appendChild(actions);
  area.appendChild(card);
}

async function sendApproval(approvalId, action, choiceValue) {
  try {
    // Choice operations: send the value as a command (same path as Flutter) so
    // the CCC session actually receives the choice text followed by Enter.
    if (choiceValue !== undefined) {
      await rpc("command.send", {
        session_id: state.active,
        client_msg_id: genClientMsgId(),
        command: choiceValue
      });
    } else {
      await rpc("message.approve", {
        session_id: state.active,
        approval_id: approvalId,
        action,
        idempotency_key: `idem_${approvalId}_${action}`
      });
    }
    state.chat.pendingApproval = null;
    renderApproval();
  } catch (error) {
    toast(`approve: ${error.message}`, true);
  }
}

/* ---------------- Sending ---------------- */

async function sendPrompt(event) {
  event.preventDefault();
  await sendPromptText(el("prompt").value);
}

async function sendPromptText(rawText) {
  const textarea = el("prompt");
  const text = rawText.trim();
  if (!text || !state.active) return;
  const clientMsgId = genClientMsgId();
  const isCommand = text.startsWith("/");

  // Optimistic bubble.
  const item = { id: clientMsgId, role: "user", text, seq: null, pending: true };
  state.chat.byClientId.set(clientMsgId, item);
  state.chat.items.push(item);
  renderMessages();
  textarea.value = "";

  try {
    if (isCommand) {
      await rpc("command.send", { session_id: state.active, client_msg_id: clientMsgId, command: text });
    } else {
      await rpc("message.send", { session_id: state.active, client_msg_id: clientMsgId, text });
    }
    item.pending = false;
    renderMessages();
  } catch (error) {
    item.pending = false;
    item.failed = true;
    renderMessages();
    toast(`send: ${error.message}`, true);
  }
}

async function interruptSession() {
  if (!state.active) return;
  try {
    await rpc("message.interrupt", { session_id: state.active });
    toast("Interrupt sent");
  } catch (error) {
    toast(`interrupt: ${error.message}`, true);
  }
}

async function killSession() {
  if (!state.active) return;
  if (!confirm("Kill this session?")) return;
  try {
    await rpc("session.kill", { session_id: state.active });
    toast("Session killed");
    await refreshSessions();
  } catch (error) {
    toast(`kill: ${error.message}`, true);
  }
}

async function loadMoreHistory() {
  if (!state.chat || !state.chat.hasMore) return;
  try {
    const data = await rpc("messages.list", {
      session_id: state.active,
      before: state.chat.nextBefore || undefined,
      limit: 50
    });
    const older = [];
    for (const item of data.items || []) {
      const rawText = item.text || item.content || "";
      if (!rawText.trim()) continue;
      const role = item.role || "assistant";
      older.push({
        id: item.id || item.message_id || `msg_${item.message_seq || item.seq}`,
        role,
        text: role === "assistant" ? formatAssistantText(rawText) : rawText,
        seq: item.seq ?? item.message_seq ?? null
      });
    }
    const container = el("messages");
    const prevScrollHeight = container.scrollHeight;
    const prevScrollTop = container.scrollTop;
    state.chat.items = [...older, ...state.chat.items];
    state.chat.hasMore = Boolean(data.has_more);
    state.chat.nextBefore = data.next_before ?? null;
    el("history-bar").hidden = !state.chat.hasMore;
    renderMessages();
    // Restore reading position: compensate for the height added by prepended items.
    container.scrollTop = prevScrollTop + (container.scrollHeight - prevScrollHeight);
  } catch (error) {
    toast(`messages.list: ${error.message}`, true);
  }
}

/* ---------------- Image upload ---------------- */

async function uploadImage(file) {
  if (!state.active) return;
  try {
    const begin = await rpc("image.upload.begin", {
      session_id: state.active,
      name: file.name,
      mime: file.type,
      bytes: file.size
    });
    const chunkSize = begin.chunk_size || 96 * 1024;
    const buffer = new Uint8Array(await file.arrayBuffer());
    let index = 0;
    for (let offset = 0; offset < buffer.length; offset += chunkSize) {
      const slice = buffer.subarray(offset, Math.min(offset + chunkSize, buffer.length));
      await rpc("image.upload.chunk", {
        session_id: state.active,
        upload_id: begin.upload_id,
        index,
        data: bytesToBase64(slice)
      });
      index += 1;
    }
    const finished = await rpc("image.upload.finish", {
      session_id: state.active,
      upload_id: begin.upload_id
    });
    const filePath = finished.file?.path || finished.file?.relative_path;
    state.uploads.push({ path: filePath, name: file.name });
    appendUploadPathToPrompt(filePath);
    renderAttachPreview();
    toast(`Uploaded ${file.name}`);
  } catch (error) {
    toast(`image upload: ${error.message}`, true);
  }
}

function bytesToBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function appendUploadPathToPrompt(path) {
  if (!path) return;
  const textarea = el("prompt");
  const prefix = textarea.value && !textarea.value.endsWith("\n") ? textarea.value + "\n" : textarea.value;
  textarea.value = `${prefix}${path}`;
}

function renderAttachPreview() {
  const node = el("attach-preview");
  if (state.uploads.length === 0) { node.hidden = true; node.innerHTML = ""; return; }
  node.hidden = false;
  node.innerHTML = "";
  state.uploads.forEach((upload, idx) => {
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.innerHTML = `${escapeHtml(upload.name)} <button title="remove">✕</button>`;
    chip.querySelector("button").onclick = () => {
      state.uploads.splice(idx, 1);
      renderAttachPreview();
    };
    node.appendChild(chip);
  });
}

/* ---------------- Files & stats ---------------- */

async function refreshFiles() {
  if (!state.active) return;
  try {
    const data = await rpc("file.list", { session_id: state.active });
    const list = el("file-list");
    list.innerHTML = "";
    for (const file of data.files || []) {
      const li = document.createElement("li");
      li.textContent = file.relative_path || file.path;
      li.title = file.path;
      li.onclick = () => readFile(file.relative_path || file.path);
      list.appendChild(li);
    }
  } catch (error) {
    toast(`file.list: ${error.message}`, true);
  }
}

async function readFile(path) {
  try {
    const data = await rpc("file.read", { session_id: state.active, path });
    const view = el("file-view");
    view.hidden = false;
    const trunc = data.truncated ? "\n\n… (truncated)" : "";
    view.textContent = `# ${data.relative_path || data.path} (${data.bytes} bytes)\n\n${data.content}${trunc}`;
  } catch (error) {
    toast(`file.read: ${error.message}`, true);
  }
}

async function refreshStats() {
  try {
    const data = await rpc("system.stats");
    el("stats-view").textContent = JSON.stringify(data, null, 2);
  } catch (error) {
    el("stats-view").textContent = `error: ${error.message}`;
  }
}

/* ---------------- Events router ---------------- */

function handleEvent(message) {
  logLine("evt", `⚡ ${message.event?.kind}`, { seq: message.seq, session: message.session_id });
  // Always reflect state/attention changes in the session list.
  const summary = state.sessions.get(message.session_id);
  const kind = message.event?.kind;
  if (summary) {
    if (kind === "state_changed") {
      summary.state = message.event.state;
      summary.needs_attention = summary.state === "approval" || summary.state === "choosing";
    } else if (kind === "approval_requested") {
      summary.needs_attention = true;
    } else if (kind === "session_ended") {
      summary.state = "ended";
    }
    renderSessionList();
  }
  // Render into the active chat if it belongs to it.
  if (message.session_id === state.active && state.chat) {
    applyEventToChat(message, false);
    // approval_requested/resolved only update the approval card (handled inside
    // applyEventToChat), not the message list — skip the full DOM rebuild.
    const approvalOnly = kind === "approval_requested" || kind === "approval_resolved";
    if (!approvalOnly) renderMessages();
  }
}

/* ---------------- Tabs ---------------- */

function setupTabs() {
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.onclick = () => {
      document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
      tab.classList.add("active");
      const name = tab.dataset.tab;
      document.querySelectorAll(".tab-panel").forEach((panel) => {
        panel.hidden = panel.dataset.panel !== name;
      });
      if (name === "stats") refreshStats();
    };
  });
}

function showMobilePanel(name) {
  const workspace = el("workspace");
  workspace.classList.remove("mobile-panel-sessions", "mobile-panel-chat", "mobile-panel-tools");
  workspace.classList.add(`mobile-panel-${name}`);
  document.querySelectorAll(".mobile-tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.mobilePanel === name);
  });
}

function setupMobileWorkspaceTabs() {
  document.querySelectorAll(".mobile-tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      showMobilePanel(tab.dataset.mobilePanel || "chat");
    });
  });
  showMobilePanel("sessions");
}

/* ---------------- Wiring ---------------- */

function init() {
  el("ws-url").value = localStorage.getItem(LS_URL) || defaultWsUrl();
  const savedToken = localStorage.getItem(LS_TOKEN);
  if (savedToken) {
    el("token").value = savedToken;
    el("remember").checked = true;
  }

  el("auth-form").addEventListener("submit", (event) => {
    event.preventDefault();
    el("auth-error").hidden = true;
    connect(el("ws-url").value.trim(), el("token").value);
  });
  el("btn-disconnect").addEventListener("click", disconnect);
  el("btn-refresh-sessions").addEventListener("click", refreshSessions);
  el("run-form").addEventListener("submit", runSession);
  el("btn-quick-run").addEventListener("click", quickRunSession);
  el("run-backend").addEventListener("change", () => {
    localStorage.setItem(LS_RUN_BACKEND, el("run-backend").value);
    updateQuickRun();
  });
  el("run-workspace").addEventListener("change", () => {
    localStorage.setItem(LS_RUN_WORKSPACE, el("run-workspace").value);
    updateQuickRun();
  });
  el("btn-new-workspace").addEventListener("click", createWorkspace);
  el("send-form").addEventListener("submit", sendPrompt);
  el("btn-interrupt").addEventListener("click", interruptSession);
  el("btn-kill").addEventListener("click", killSession);
  el("btn-load-more").addEventListener("click", loadMoreHistory);
  el("btn-refresh-files").addEventListener("click", refreshFiles);
  el("btn-refresh-stats").addEventListener("click", refreshStats);
  el("btn-clear-log").addEventListener("click", () => { el("event-log").innerHTML = ""; });

  el("run-target").addEventListener("change", () => {
    const mode = el("run-target").value;
    el("workspace-field").hidden = mode !== "workspace";
    el("cwd-field").hidden = mode !== "cwd";
  });

  el("btn-attach").addEventListener("click", () => el("image-input").click());
  el("image-input").addEventListener("change", (event) => {
    const file = event.target.files[0];
    if (file) uploadImage(file);
    event.target.value = "";
  });

  el("prompt").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      el("send-form").requestSubmit();
    }
  });
  document.querySelectorAll("#prompt-shortcuts button").forEach((button) => {
    button.addEventListener("click", () => {
      const prompt = button.dataset.prompt || button.textContent || "";
      sendPromptText(prompt);
    });
  });

  setupTabs();
  setupMobileWorkspaceTabs();
  applyRunDefaults();
  updateQuickRun();
  updateComposerEnabled("");
}

document.addEventListener("DOMContentLoaded", init);
