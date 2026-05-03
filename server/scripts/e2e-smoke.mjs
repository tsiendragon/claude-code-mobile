import { WebSocket } from "ws";

const url = process.env.CCM_E2E_URL ?? "ws://127.0.0.1:8910/ws";
const token = process.env.CCM_E2E_TOKEN ?? process.env.CCM_TOKEN;
const workspaceName = process.env.CCM_E2E_WORKSPACE ?? `e2e-${Date.now()}`;
const runSession = process.env.CCM_E2E_RUN_SESSION !== "0";
const prompt = process.env.CCM_E2E_PROMPT;

if (!token) {
  console.error("CCM_E2E_TOKEN or CCM_TOKEN is required");
  process.exit(2);
}

const socket = new WebSocket(url);
const pending = new Map();
let requestCounter = 0;

socket.on("message", (data) => {
  const message = JSON.parse(String(data));
  if (message.type !== "response") return;
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  clearTimeout(entry.timer);
  if (message.ok) {
    entry.resolve(message.data ?? {});
  } else {
    const error = new Error(message.error?.message ?? "request failed");
    error.code = message.error?.code;
    entry.reject(error);
  }
});

socket.on("error", (error) => {
  for (const entry of pending.values()) entry.reject(error);
  pending.clear();
});

await waitForOpen(socket);

let sessionId;
try {
  const auth = await request("auth", {
    protocol_version: 1,
    authorization: `Bearer ${token}`
  });
  console.log(JSON.stringify({ step: "auth", ok: true, principal_id: auth.principal_id }));

  const workspaceData = await request("workspace.create", { name: workspaceName });
  const workspace = workspaceData.workspace;
  console.log(JSON.stringify({ step: "workspace.create", ok: true, workspace }));

  const listed = await request("workspace.list");
  const hasWorkspace = listed.workspaces?.some((item) => item.id === workspaceName) ?? false;
  console.log(JSON.stringify({ step: "workspace.list", ok: hasWorkspace, count: listed.workspaces?.length ?? 0 }));
  if (!hasWorkspace) throw new Error("created workspace not found in workspace.list");

  if (runSession) {
    const session = await request("session.run", {
      name: `Smoke ${workspaceName}`,
      workspace_id: workspaceName,
      backend: "claude"
    }, 45000);
    sessionId = session.session_id;
    console.log(JSON.stringify({ step: "session.run", ok: true, session_id: sessionId, state: session.state }));

    const attached = await request("session.attach", { session_id: sessionId }, 45000);
    console.log(JSON.stringify({ step: "session.attach", ok: true, last_seq: attached.last_seq }));

    if (prompt) {
      const clientMsgId = `cmsg_${Date.now()}`;
      await request("message.send", {
        session_id: sessionId,
        client_msg_id: clientMsgId,
        text: prompt
      }, 20000);
      console.log(JSON.stringify({ step: "message.send", ok: true, client_msg_id: clientMsgId }));
    }
  }
} finally {
  if (sessionId) {
    try {
      await request("session.kill", { session_id: sessionId }, 20000);
      console.log(JSON.stringify({ step: "session.kill", ok: true, session_id: sessionId }));
    } catch (error) {
      console.error(JSON.stringify({ step: "session.kill", ok: false, code: error.code, message: error.message }));
    }
  }
  socket.close();
}

function request(type, data = {}, timeoutMs = 10000) {
  const id = `req_${++requestCounter}`;
  const payload = JSON.stringify({ type, id, ...data });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${type} timed out`));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    socket.send(payload);
  });
}

function waitForOpen(ws) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("websocket open timed out")), 5000);
    ws.once("open", () => {
      clearTimeout(timer);
      resolve();
    });
    ws.once("error", reject);
  });
}
