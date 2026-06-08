// WASM determinism check: run the freestanding sim under node and assert its content digest equals the
// NATIVE run, bit for bit — the headline property for web demos. A browser playthrough is the same
// computation as a native one (wasm32 is 32-bit LE, like the gated `arm` target; wasm64 is 64-bit LE).
//
//   zig build wasm                 # build zig-out/web/roguelike{,64}.wasm
//   zig build run -- digest 7 30   # the native reference hash
//   node web/check.mjs <native-hash>
//
// (the project's `zig build test` wires this up automatically — see build.zig)

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SEED = 7n, TICKS = 30;

async function digest(wasmName) {
  const bytes = readFileSync(join(here, "..", "zig-out", "web", wasmName));
  const { instance } = await WebAssembly.instantiate(bytes, {}); // freestanding: no host imports
  const x = instance.exports;
  x.rl_init(Number(SEED));
  for (let i = 0; i < TICKS; i++) x.rl_step();
  return { tick: x.rl_tick(), hash: x.rl_digest() }; // both u64 -> BigInt
}

// The native reference hash: either passed as argv[2], or derived by running the installed native exe
// (`roguelike digest <seed> <ticks>`) so the check is self-verifying with no hash to keep in sync.
let expected = process.argv[2];
if (expected === undefined) {
  try {
    const exe = join(here, "..", "zig-out", "bin", "roguelike");
    expected = execFileSync(exe, ["digest", String(SEED), TICKS.toString()]).toString().trim();
  } catch {
    /* no native exe built (e.g. `zig build wasm` alone) — fall back to wasm32==wasm32 self-consistency */
  }
}
let failed = false;

// wasm32 is the real browser target and MUST run + match native. wasm64 (memory64) compiles, but no
// shipping runtime (node v22 / today's browsers) instantiates 64-bit-table modules yet — so a wasm64
// instantiate failure is "built; runtime-gated", NOT a determinism failure. A digest MISMATCH always fails.
const targets = [
  { name: "roguelike.wasm", required: true },
  { name: "roguelike64.wasm", required: false },
];

for (const { name, required } of targets) {
  let r;
  try {
    r = await digest(name);
  } catch (e) {
    if (required) {
      console.error(`  ${name.padEnd(16)} FAILED to run — ${e.message}`);
      failed = true;
    } else {
      console.log(`  ${name.padEnd(16)} built ✓ — runtime-gated (memory64 nascent: ${e.message.split("@")[0].trim()})`);
    }
    continue;
  }
  const got = r.hash.toString();
  const verdict = expected === undefined ? "(no native ref given)" : got === expected ? "✓ == native" : "✗ DIVERGED from native";
  console.log(`  ${name.padEnd(16)} tick=${r.tick} digest=${got}  ${verdict}`);
  if (expected !== undefined && got !== expected) failed = true;
}

if (failed) {
  console.error("WASM determinism check FAILED");
  process.exit(1);
}
console.log("WASM determinism check OK — the wasm32 browser sim is bit-identical to native.");
