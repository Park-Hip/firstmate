import { spawn } from "node:child_process";

// Pi runs extensions, their tools, and their event handlers on the single
// JavaScript thread that also draws the TUI and reads the keyboard, and it
// starts no worker for them. A spawnSync call from an extension therefore
// stops repaint and key echo for the child's whole lifetime, which a
// supervision outcome made visible as a subsecond freeze every time one
// arrived (docs/pi-supervision-branch.md "Off-thread delivery").
//
// This is the one owner of that replacement: the same capture shape spawnSync
// returns, produced by an awaited spawn so the event loop keeps running while
// the child does. Callers keep their own ordering guarantees - awaiting here
// yields the thread, so anything that must not interleave belongs behind a
// serializing queue in the caller.
//
// Like spawnSync, a spawn that never starts and a child killed by a signal
// both report a null status rather than throwing, so a caller's existing
// "status !== 0" failure branch keeps its meaning unchanged.

export interface AsyncExecResult {
  /** Exit code, or null when the child was signalled or never started. */
  status: number | null;
  stdout: string;
  stderr: string;
}

export interface AsyncExecOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Written to the child's stdin, which is closed either way. */
  input?: string;
  /**
   * Upper bound on captured stdout, mirroring spawnSync's maxBuffer: a child
   * that exceeds it is killed and reported as a failure rather than allowed
   * to grow without limit. Unset means no bound.
   */
  maxBuffer?: number;
}

export function runCommandAsync(
  command: string,
  args: readonly string[],
  options: AsyncExecOptions = {},
): Promise<AsyncExecResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (status: number | null, detail = ""): void => {
      if (settled) return;
      settled = true;
      resolve({ status, stdout, stderr: detail ? `${stderr}${detail}` : stderr });
    };
    let child;
    try {
      child = spawn(command, [...args], {
        cwd: options.cwd,
        env: options.env,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      finish(null, error instanceof Error ? error.message : String(error));
      return;
    }
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
      if (options.maxBuffer !== undefined && stdout.length > options.maxBuffer) {
        child.kill();
        finish(null, `stdout exceeded ${options.maxBuffer} bytes`);
      }
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    // "close" rather than "exit": it fires once the captured stdio streams are
    // drained, so no output is lost the way an early "exit" would lose it.
    child.on("close", (code) => finish(code));
    child.on("error", (error: Error) => finish(null, error.message));
    if (child.stdin) {
      // A child that exits before reading stdin makes the write fail with
      // EPIPE, which is its answer, not this helper's failure.
      child.stdin.on("error", () => {});
      child.stdin.end(options.input ?? "");
    }
  });
}
