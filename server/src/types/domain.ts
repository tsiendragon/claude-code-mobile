export type SessionState =
  | "ready"
  | "thinking"
  | "approval"
  | "choosing"
  | "error"
  | "ended";

export type SessionBackend = "claude" | "codex" | "opencode" | "cursor";

export type ApprovalAction = "yes" | "no" | "approve" | "reject" | "always" | "choice";

export type ApprovalScope = {
  sessionOnly: boolean;
  operationKind?: ApprovalRecord["operationKind"];
};

export type ApprovalRecord = {
  approvalId: string;
  sessionId: string;
  operationKind: "file_edit" | "command" | "choice" | "unknown";
  description: string;
  paths: string[];
  diffSummary?: string;
  contentHash: string;
  actions: ApprovalAction[];
  scope?: ApprovalScope;
  expiresAt: string;
  status: "pending" | "approved" | "rejected" | "expired" | "interrupted";
};

export type SessionCapabilities = {
  canSendWhenThinking: boolean;
  canSendWhenError: boolean;
  canInterrupt: boolean;
  canApprove: boolean;
};

export type SessionRecord = {
  sessionId: string;
  name: string;
  backend: SessionBackend;
  cwd: string;
  cccName: string;
  state: SessionState;
  createdAt: string;
  updatedAt: string;
  lastSeq: number;
  lastSnapshotHash?: string;
  pendingApproval?: ApprovalRecord;
  capabilities: SessionCapabilities;
};

export type DomainEvent =
  | { kind: "state_changed"; state: SessionState; previousState?: SessionState }
  | { kind: "user_message"; clientMsgId: string; text: string; textBytes: number }
  | { kind: "message_delivered"; clientMsgId: string }
  | { kind: "message_failed"; clientMsgId: string; code: string; message: string }
  | { kind: "assistant_message"; messageId?: string; text: string; snapshot?: boolean }
  | { kind: "approval_requested"; approval: ApprovalRecord }
  | { kind: "approval_resolved"; approvalId: string; status: ApprovalRecord["status"] }
  | { kind: "session_ended" };

export type StoredEvent = {
  type: "event";
  session_id: string;
  seq: number;
  event: DomainEvent;
  created_at: string;
};

export type EventGap = {
  type: "EVENT_GAP";
  latestSeq: number;
  oldestSeq?: number;
};
