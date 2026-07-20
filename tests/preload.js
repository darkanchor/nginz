// This file runs before all tests to ensure nginz is built
import { ensureBuild } from "./harness.js";
import { spawnSync } from "bun";

ensureBuild();

// Drop orphaned nginz masters left behind when a previous bun process was
// killed mid-suite (bind "Address already in use" on the next run).
// Use the executable basename only — avoid -f patterns that could match the
// test runner's command line.
try {
  spawnSync(["pkill", "-x", "nginz"], {
    stdout: "ignore",
    stderr: "ignore",
  });
} catch {}
try {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
} catch {}
