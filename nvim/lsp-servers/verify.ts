#!/usr/bin/env bun
/**
 * Proves each language server completes a real LSP `initialize` handshake when
 * launched by bun — the exact invocation lsp.lua uses.
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

const BIN = join(dirname(fileURLToPath(import.meta.url)), "node_modules", ".bin");

// Args are NOT uniform — bash-language-server rejects --stdio and wants `start`.
// Verified individually; don't assume a new server follows the majority.
const SERVERS: Array<{ cmd: string; args: string[] }> = [
  { cmd: "typescript-language-server", args: ["--stdio"] },
  { cmd: "yaml-language-server", args: ["--stdio"] },
  { cmd: "vscode-json-language-server", args: ["--stdio"] },
  { cmd: "vscode-css-language-server", args: ["--stdio"] },
  { cmd: "vscode-html-language-server", args: ["--stdio"] },
  { cmd: "bash-language-server", args: ["start"] },
];

const TIMEOUT_MS = 20_000;

function handshake(cmd: string, args: string[]): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn("bun", [join(BIN, cmd), ...args], {
      stdio: ["pipe", "pipe", "ignore"],
    });

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
for (const { cmd, args } of SERVERS) {
  const ok = await handshake(cmd, args);
  console.log(`  ${ok ? "pass" : "FAIL"}  ${cmd.padEnd(30)} ${args.join(" ")}`);
  if (!ok) failed++;
}

console.log("");
if (failed === 0) {
  console.log(`ALL PASS — ${SERVERS.length} servers completed an LSP handshake under bun`);
} else {
  console.log(`${failed}/${SERVERS.length} FAILED`);
  process.exit(1);
}
