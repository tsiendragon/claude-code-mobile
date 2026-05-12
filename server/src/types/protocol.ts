import type { ApprovalAction, SessionBackend, SessionState } from "./domain.js";

export const PROTOCOL_VERSION = 1;

export type RequestEnvelope = {
  type: string;
  id: string;
  protocol_version?: number;
  [key: string]: unknown;
};

export type AuthRequest = RequestEnvelope & {
  type: "auth";
  token?: string;
  authorization?: string;
  protocol_version: number;
};

export type SessionRunRequest = RequestEnvelope & {
  type: "session.run";
  name: string;
  backend?: SessionBackend;
  cwd?: string;
  workspace_id?: string;
};

export type SessionIdRequest = RequestEnvelope & {
  session_id: string;
};

export type MessageSendRequest = SessionIdRequest & {
  type: "message.send";
  client_msg_id: string;
  text: string;
};

export type MessageApproveRequest = SessionIdRequest & {
  type: "message.approve";
  approval_id: string;
  action: ApprovalAction;
  idempotency_key?: string;
};

export type EventsSyncRequest = SessionIdRequest & {
  type: "events.sync";
  after?: number;
  after_seq?: number;
};

export type MessagesListRequest = SessionIdRequest & {
  type: "messages.list";
  before?: number;
  limit?: number;
};

export type FileReadRequest = SessionIdRequest & {
  type: "file.read";
  path: string;
};

export type SupportedRequest =
  | AuthRequest
  | RequestEnvelope
  | SessionRunRequest
  | SessionIdRequest
  | MessageSendRequest
  | MessageApproveRequest
  | MessagesListRequest
  | FileReadRequest
  | EventsSyncRequest;

export type ResponseEnvelope =
  | { type: "response"; id: string; ok: true; data: unknown }
  | {
      type: "response";
      id: string;
      ok: false;
      error: { code: string; message: string; retryable: boolean };
    };

export type SessionSummary = {
  session_id: string;
  name: string;
  backend: SessionBackend;
  cwd: string;
  state: SessionState;
  last_seq: number;
  needs_attention: boolean;
};
