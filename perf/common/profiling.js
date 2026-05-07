import { existsSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { join } from "path";
import { spawn } from "bun";
import { execSync } from "child_process";
import os from "os";
import { commandExists } from "./system.js";

function readFileMaybe(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function snapshotPid(pid) {
  if (!pid || !existsSync(`/proc/${pid}`)) return null;
  const status = readFileMaybe(`/proc/${pid}/status`);
  const stat = readFileMaybe(`/proc/${pid}/stat`);
  const limits = readFileMaybe(`/proc/${pid}/limits`);
  const cmdline = readFileMaybe(`/proc/${pid}/cmdline`).replaceAll("\u0000", " ").trim();
  return {
    pid,
    cmdline,
    status,
    stat,
    limits,
  };
}

/** Resolve a parent PID to all descendant PIDs (children, grandchildren, etc). */
function resolvePidTree(parentPid) {
  const result = [parentPid];
  try {
    const taskDir = `/proc/${parentPid}/task`;
    if (existsSync(taskDir)) {
      for (const tid of readdirSync(taskDir)) {
        const childrenPath = `/proc/${parentPid}/task/${tid}/children`;
        const children = readFileMaybe(childrenPath).trim();
        if (children) {
          for (const childPid of children.split(/\s+/)) {
            const cpid = parseInt(childPid, 10);
            if (cpid > 0) {
              result.push(...resolvePidTree(cpid));
            }
          }
        }
      }
    }
  } catch {}
  // Deduplicate
  return [...new Set(result)];
}

function snapshotSystem() {
  return {
    generated_at: new Date().toISOString(),
    loadavg: os.loadavg(),
    uptime: readFileMaybe("/proc/uptime").trim(),
    meminfo: readFileMaybe("/proc/meminfo"),
  };
}

export function normalizeProfileMode(requestedMode) {
  if (!requestedMode || requestedMode === "snapshot") return { requested: requestedMode || "snapshot", effective: "snapshot", reason: null };
  if (requestedMode === "none") return { requested: "none", effective: "none", reason: null };
  if (requestedMode === "perf-stat") {
    if (!commandExists("perf")) {
      return { requested: "perf-stat", effective: "snapshot", reason: "perf not found; fell back to snapshot" };
    }
    return { requested: "perf-stat", effective: "perf-stat", reason: null };
  }
  return { requested: requestedMode, effective: "snapshot", reason: `unknown profiling mode '${requestedMode}', fell back to snapshot` };
}

export function captureSnapshotSummary({ mode, pids, reason = null }) {
  const normalized = normalizeProfileMode(mode);
  return {
    requested_mode: normalized.requested,
    effective_mode: normalized.effective === "perf-stat" ? "snapshot" : normalized.effective,
    fallback_reason: normalized.effective === "perf-stat"
      ? "perf-stat capture not started; recorded snapshot only"
      : normalized.reason,
    reason,
    started_at: new Date().toISOString(),
    finished_at: new Date().toISOString(),
    pids: pids.filter(Boolean),
    before: {
      system: snapshotSystem(),
      processes: pids.map(snapshotPid).filter(Boolean),
    },
    after: {
      system: snapshotSystem(),
      processes: pids.map(snapshotPid).filter(Boolean),
    },
    perf_stat_path: null,
  };
}

export function writeSnapshotSummary(profilingDir, summary) {
  const summaryPath = join(profilingDir, "summary.json");
  writeFileSync(summaryPath, JSON.stringify(summary, null, 2));
  return summaryPath;
}

/**
 * Run `perf stat -p <pids>` via a shell wrapper so signal delivery is
 * reliable across process trees.  Bun's `proc.kill()` does not reliably
 * deliver SIGINT to perf's child `sleep` process, but the shell's `kill`
 * builtin handles process-group signalling correctly.
 */

export async function startProfiling({ mode, pids, profilingDir }) {
  const normalized = normalizeProfileMode(mode);
  const session = {
    requested_mode: normalized.requested,
    effective_mode: normalized.effective,
    fallback_reason: normalized.reason,
    pids: pids.filter(Boolean),
    started_at: new Date().toISOString(),
    before: {
      system: snapshotSystem(),
      processes: pids.map(snapshotPid).filter(Boolean),
    },
    perfStatPath: join(profilingDir, "perf-stat.txt"),
    processRef: null,
    _fifoPath: null,
  };

  if (normalized.effective === "perf-stat" && session.pids.length > 0) {
    // Resolve all child PIDs (nginx workers are children of the master)
    const allPids = [];
    for (const pid of session.pids) {
      allPids.push(...resolvePidTree(pid));
    }
    const uniquePids = [...new Set(allPids)];

    const fifoPath = session.perfStatPath + ".fifo";
    session._fifoPath = fifoPath;

    // Create FIFO before spawning
    try { execSync(`rm -f "${fifoPath}" && mkfifo "${fifoPath}"`); } catch {}

    // perf stat monitors all resolved pids until the FIFO receives data
    session.processRef = spawn([
      "perf", "stat",
      "-x,",
      "-e", "task-clock,cycles,instructions,branches,branch-misses,cache-references,cache-misses,context-switches,cpu-migrations,page-faults",
      "-p", uniquePids.join(","),
      "-o", session.perfStatPath,
      "--",
      "sh", "-c", `cat "${fifoPath}" >/dev/null`,
    ], {
      stdout: "ignore",
      stderr: "ignore",
      cwd: process.cwd(),
      env: process.env,
    });
  }

  return session;
}

export async function stopProfiling(session, profilingDir) {
  if (session.processRef && session._fifoPath) {
    // Use a bounded shell write so a missing FIFO reader cannot hang teardown.
    try {
      execSync(`timeout 1 sh -c 'printf x > "${session._fifoPath}"'`);
    } catch {}
    // Clean up FIFO
    try { execSync(`rm -f "${session._fifoPath}"`); } catch {}
    // Wait briefly for perf to flush output
    await new Promise(r => setTimeout(r, 500));
    try { session.processRef.kill("SIGKILL"); } catch {}
  } else if (session.processRef) {
    session.processRef.kill("SIGINT");
    try { await session.processRef.exited; } catch {}
  }

  const summary = {
    requested_mode: session.requested_mode,
    effective_mode: session.effective_mode,
    fallback_reason: session.fallback_reason,
    started_at: session.started_at,
    finished_at: new Date().toISOString(),
    pids: session.pids,
    before: session.before,
    after: {
      system: snapshotSystem(),
      processes: session.pids.map(snapshotPid).filter(Boolean),
    },
    perf_stat_path: session.effective_mode === "perf-stat" ? "perf-stat.txt" : null,
  };

  const summaryPath = join(profilingDir, "summary.json");
  writeFileSync(summaryPath, JSON.stringify(summary, null, 2));
  return summary;
}
