// Runs the cloud Worker (cloud/) under `wrangler dev --local` for the tests. Each run works in a
// temporary copy of cloud/ with its own .dev.vars and local state, so a developer's
// cloud/.dev.vars and .wrangler/ are never used or changed. The first run needs network access
// (npx downloads wrangler@4.143.0).

import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const CLOUD = fileURLToPath(new URL("../../cloud/", import.meta.url));
export const STARTUP_MS = 240_000;

const ENV = { ...process.env, WRANGLER_SEND_METRICS: "false", NO_COLOR: "1", FORCE_COLOR: "0", CI: "1" };

// Every `wrangler dev` still running. One that a test never got to stop (a hook that timed out
// while it started) must not keep the test file's process alive, nor outlive it: the children are
// unreferenced, and whatever is left is killed when the process exits.
const running = new Set();

function killNow(child) {
  try {
    if (process.platform === "win32") {
      spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
    } else {
      process.kill(-child.pid, "SIGKILL");
    }
  } catch {
    // Already gone.
  }
}

process.on("exit", () => {
  for (const child of running) killNow(child);
});

export function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// devVars: the Worker's .dev.vars (secrets and overridden vars). migrate: apply the D1 migrations
// to the local database first. scheduled: GET /__scheduled runs the daily housekeeping.
export async function startWorker({ devVars = {}, migrate = false, scheduled = false } = {}) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "directorlink-cloud-"));
  cpSync(CLOUD, dir, { recursive: true, filter: (source) => !/[\\/](\.wrangler|node_modules|\.dev\.vars[^\\/]*)$/.test(source) });
  writeFileSync(path.join(dir, ".dev.vars"), Object.entries(devVars).map(([name, value]) => `${name}=${value}\n`).join(""));
  const cleanup = () => {
    try {
      rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
    } catch {
      // Windows can hold workerd's files a little longer; the temporary folder is harmless.
    }
  };

  if (migrate) {
    const applied = spawnSync("npx --yes wrangler@4.143.0 d1 migrations apply directorlink --local", {
      cwd: dir,
      shell: true,
      windowsHide: true,
      encoding: "utf8",
      env: ENV,
      timeout: STARTUP_MS,
    });
    if (applied.status !== 0) {
      cleanup();
      throw new Error(`D1 migrations failed:\n${applied.stdout}\n${applied.stderr}`);
    }
  }

  const port = await freePort();
  const inspectorPort = await freePort();
  const command = `npx --yes wrangler@4.143.0 dev --local --ip 127.0.0.1 --port ${port} --inspector-port ${inspectorPort} --no-show-interactive-dev-session${scheduled ? " --test-scheduled" : ""}`;
  const child = spawn(command, {
    cwd: dir,
    shell: true,
    detached: process.platform !== "win32", // its own process group, so the whole tree can be stopped
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: ENV,
  });
  running.add(child);
  child.once("exit", () => running.delete(child));
  child.unref();
  child.stdout.unref?.();
  child.stderr.unref?.();
  const lines = [];
  const collect = (chunk) => {
    lines.push(...chunk.toString("utf8").split(/\r?\n/).filter(Boolean));
    lines.splice(0, Math.max(0, lines.length - 200));
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  const output = () => lines.join("\n");

  const base = `http://127.0.0.1:${port}`;
  const stop = async () => {
    await stopTree(child);
    cleanup();
  };
  try {
    await waitForHealth(base, child, output);
  } catch (error) {
    await stop();
    throw error;
  }
  // dir: the Worker's temporary copy (a change to its code reloads it, as a deploy restarts it).
  return { http: base, ws: `ws://127.0.0.1:${port}`, dir, output, stop };
}

async function waitForHealth(base, child, output) {
  const deadline = Date.now() + STARTUP_MS;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`wrangler dev exited with code ${child.exitCode}:\n${output()}`);
    }
    try {
      const response = await fetch(`${base}/health`, { signal: AbortSignal.timeout(2000) });
      if (response.ok && (await response.json()).status === "ok") {
        return;
      }
    } catch {
      // Not listening yet.
    }
    await sleep(500);
  }
  throw new Error(`wrangler dev did not answer ${base}/health within ${STARTUP_MS / 1000} s:\n${output()}`);
}

async function stopTree(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  const exited = once(child, "exit");
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } else {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      // Already gone.
    }
    const kill = setTimeout(() => {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        // Already gone.
      }
    }, 5000);
    await Promise.race([exited, sleep(10_000)]);
    clearTimeout(kill);
  }
  await Promise.race([exited, sleep(10_000)]);
}
