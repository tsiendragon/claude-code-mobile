import type { ApprovalRecord, SessionState } from "../types/domain.js";

export type CccSession = {
  name: string;
  cwd?: string;
  state?: SessionState;
  alive?: boolean;
};

export type CccReadResult = {
  state: SessionState;
  output?: string;
  pendingApproval?: Omit<ApprovalRecord, "approvalId" | "sessionId" | "expiresAt" | "status">;
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
