import type { ApprovalChoice, ApprovalRecord, SessionBackend, SessionState } from "../types/domain.js";

export type CccSession = {
  name: string;
  cwd?: string;
  backend?: SessionBackend;
  state?: SessionState;
  alive?: boolean;
};

export type CccTranscriptItem = {
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt?: string;
  snapshot?: boolean;
};

export type CccReadResult = {
  state: SessionState;
  output?: string;
  items?: CccTranscriptItem[];
  pendingApproval?: Omit<ApprovalRecord, "approvalId" | "sessionId" | "expiresAt" | "status"> & {
    choices?: ApprovalChoice[];
  };
};

export type CccCommandResult<T> =
  | {
      ok: true;
      stdout: string;
      stderr: string;
      data: T;
    }
  | {
      ok: false;
      stdout: string;
      stderr: string;
      code: "CCC_COMMAND_FAILED" | "CCC_TIMEOUT";
      message: string;
    };
