#!/usr/bin/env bun
/**
 * Proves each language server completes a real LSP `initialize` handshake when
 * launched the way lsp_servers.lua launches it: through bun, or for tsc, as
 * the native binary with no runtime at all.
 *
 *   bun nvim/lsp-servers/verify.ts
 *
 * Weaker checks are actively misleading here, and each one fooled me once while
 * building this:
 *
 *   --version      three of these servers reject it and exit non-zero *under
 *                  node too*, which reads as a bun incompatibility and isn't.
 *   exit code      an LSP server handed EOF on stdin exits non-zero by design.
 *   "starts clean" says nothing about whether it can actually serve.
 *
 * Only a real initialize/response round trip distinguishes "runs" from "works".
 *
 * Run it with node and npm absent from $PATH to prove the point:
 *   PATH=/minimal/bin bun nvim/lsp-servers/verify.ts
 */

import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const MODULES = join(dirname(fileURLToPath(import.meta.url)), "node_modules");
const BIN = join(MODULES, ".bin");

// TypeScript 7's language server is a native executable that the `typescript`
// package carries in a per-platform optional dependency. lsp_servers.lua runs
// it directly, with no runtime, so this does too: `direct` means spawn the
// path itself rather than `bun <path>`. The name mapping is the one
// typescript/lib/getExePath.js uses, and the one lsp_servers.lua re-derives.
const TSC = join(
  MODULES,
  "@typescript",
  `typescript-${process.platform}-${process.arch}`,
  "lib",
  process.platform === "win32" ? "tsc.exe" : "tsc",
);

// Args are NOT uniform — bash-language-server rejects --stdio and wants `start`.
// Verified individually; don't assume a new server follows the majority.
const SERVERS: Array<{ cmd: string; args: string[]; direct?: boolean }> = [
  { cmd: TSC, args: ["--lsp", "--stdio"], direct: true },
  { cmd: "yaml-language-server", args: ["--stdio"] },
  { cmd: "vscode-json-language-server", args: ["--stdio"] },
  { cmd: "vscode-css-language-server", args: ["--stdio"] },
  { cmd: "vscode-html-language-server", args: ["--stdio"] },
  { cmd: "bash-language-server", args: ["start"] },
];

const TIMEOUT_MS = 20_000;

function handshake(cmd: string, args: string[], direct = false): Promise<boolean> {
  return new Promise((resolve) => {
    const [exe, argv] = direct ? [cmd, args] : ["bun", [join(BIN, cmd), ...args]];
    const child = spawn(exe, argv, { stdio: ["pipe", "pipe", "ignore"] });

    let out = "";
    let settled = false;
    const done = (ok: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      resolve(ok);
    };

    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString();
      // The server replies with its capabilities; that's the proof it's serving.
      if (out.includes('"capabilities"') || out.includes('"result"')) done(true);
    });

    child.on("error", () => done(false));
    const timer = setTimeout(() => done(false), TIMEOUT_MS);

    const body = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { processId: null, rootUri: null, capabilities: {} },
    });
    child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  });
}

const hasNode = Bun.which("node") !== null;
const hasNpm = Bun.which("npm") !== null;
console.log(`node on PATH: ${hasNode ? "yes" : "no"}   npm on PATH: ${hasNpm ? "yes" : "no"}`);
console.log("");

let failed = 0;
for (const { cmd, args, direct } of SERVERS) {
  const ok = await handshake(cmd, args, direct);
  const name = direct ? `${cmd.split("/").at(-1)} (native)` : cmd;
  console.log(`  ${ok ? "pass" : "FAIL"}  ${name.padEnd(30)} ${args.join(" ")}`);
  if (!ok) failed++;
}

console.log("");
if (failed === 0) {
  console.log(`ALL PASS — ${SERVERS.length} servers completed an LSP handshake, none needing node`);
} else {
  console.log(`${failed}/${SERVERS.length} FAILED`);
  process.exit(1);
}
