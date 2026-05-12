import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { BridgeConfig } from "../config.js";
import type { SessionBackend } from "../types/domain.js";
import { parseCccHistory, parseCccRead, parseCccSessionList } from "./ccc-parser.js";
import type { CccCommandResult, CccReadResult, CccSession, CccTranscriptItem } from "./ccc-types.js";

const execFileAsync = promisify(execFile);

export class CccClient {
  constructor(private readonly config: Pick<BridgeConfig, "cccBin" | "cccTimeoutMs">) {}

  listSessions(): Promise<CccCommandResult<CccSession[]>> {
    return this.run(["ps", "--json"], parseCccSessionList);
  }

  runSession(name: string, cwd: string, backend: SessionBackend): Promise<CccCommandResult<{ name: string }>> {
    return this.run(this.buildRunSessionArgs(name, cwd, backend), () => ({ name }));
  }

  killSession(name: string): Promise<CccCommandResult<{ name: string }>> {
    return this.run(["kill", name], () => ({ name }));
  }

  sendMessage(name: string, text: string): Promise<CccCommandResult<{ name: string }>> {
    return this.run(["send", name, text, "--no-wait"], () => ({ name }));
  }

  approve(name: string, action: string): Promise<CccCommandResult<{ name: string; action: string }>> {
    return this.run(["approve", name, action], () => ({ name, action }));
  }

  interrupt(name: string): Promise<CccCommandResult<{ name: string }>> {
    return this.run(["interrupt", name], () => ({ name }));
  }

  input(name: string, command: string): Promise<CccCommandResult<{ name: string }>> {
    return this.run(["input", name, command], () => ({ name }));
  }

  key(name: string, key: string): Promise<CccCommandResult<{ name: string; key: string }>> {
    return this.run(["key", name, key], () => ({ name, key }));
  }

  read(name: string): Promise<CccCommandResult<CccReadResult>> {
    return this.run(["read", name, "--json"], parseCccRead);
  }

  history(name: string): Promise<CccCommandResult<CccTranscriptItem[]>> {
    return this.run(["history", name, "--json"], parseCccHistory);
  }

  buildCommand(args: string[]): { file: string; args: string[] } {
    return { file: this.config.cccBin, args };
  }

  buildRunSessionArgs(name: string, cwd: string, backend: SessionBackend = "claude"): string[] {
    const args = ["run", name, "--cwd", cwd];
    const flag = backendFlag(backend);
    if (flag) args.push(flag);
    return args;
  }

  private async run<T>(args: string[], parse: (stdout: string) => T): Promise<CccCommandResult<T>> {
    try {
      const { stdout, stderr } = await execFileAsync(this.config.cccBin, args, {
        timeout: this.config.cccTimeoutMs,
        maxBuffer: 1024 * 1024
      });
      const stdoutText = String(stdout);
      const stderrText = String(stderr);
      return { ok: true, stdout: stdoutText, stderr: stderrText, data: parse(stdoutText) };
    } catch (error) {
      const err = error as NodeJS.ErrnoException & { stdout?: string; stderr?: string; killed?: boolean };
      return {
        ok: false,
        stdout: err.stdout ?? "",
        stderr: err.stderr ?? "",
        code: err.killed ? "CCC_TIMEOUT" : "CCC_COMMAND_FAILED",
        message: err.message
      };
    }
  }
}

function backendFlag(backend: SessionBackend): string | undefined {
  switch (backend) {
    case "claude":
      return undefined;
    case "codex":
      return "--codex";
    case "opencode":
      return "--opencode";
    case "cursor":
      return "--cursor";
  }
}
