# Node binary `NODE_PLATFORM` patch

**Status:** Active
**Phase / Commit:** L4 npm intercept
**Files:** `crates/gpui_android/src/termux_bootstrap.rs` (`patch_node_platform_now`, `install_apt_node_platform_hook`)

## Problem

Every npm-distributed CLI that has prebuilt native binaries fails on Android
with:

```
Error: Missing optional dependency @<scope>/<pkg>-linux-arm64.
```

claude, codex, every Bun-compiled tool. The `optionalDependencies` map in
package.json includes `@scope/pkg-linux-arm64` and `@scope/pkg-darwin-x64`
etc. but never an `-android-arm64` entry, because nobody publishes Android
prebuilts.

## Constraint

Node's `process.platform` is set at **Node compile time**, not runtime. The
relevant code in Node's source (`src/node.cc` or its modern equivalent):

```cpp
READONLY_PROPERTY(process, "platform",
                  OneByteString(isolate, NODE_PLATFORM));
```

`NODE_PLATFORM` is a `#define` from `src/node_platform.h` set via
`./configure --dest-os=...` at build time. Termux's nodejs package builds with
`--dest-os=android`, so the literal `"android"` ends up in the binary's
`.rodata`. npm reads `process.platform` from this constant, never re-derives
it from `uname()`. Therefore:

- Layer 1 (npm flags `--platform/--arch/--libc`): works for install-time
  optional-dep selection but doesn't change `process.platform` at runtime, so
  packages re-checking it (codex's `bin/codex.js:1`) still see `'android'`.
- Layer 2 (NODE_OPTIONS preload that overrides `process.platform`): works
  but is invisible magic and breaks if anyone explicitly imports a fresh
  Node child without inheriting `NODE_OPTIONS`.
- Layer 3 (`uname()` LD_PRELOAD shim): doesn't help because Node never
  calls `uname()` for the platform string — it's a baked constant.

The deep fix is to change the constant. Two ways: rebuild Node with
`--dest-os=linux` (recipe-level, requires our termux-packages fork CI) or
patch the binary post-install (runtime, applied here).

## Solution

Locate the standalone null-bounded `\x00android\x00` literal in `$PREFIX/bin/
node` and overwrite the 7 bytes of `android` with `linux\x00\x00`. Same byte
count → no ELF section relocation. Node's `OneByteString(isolate, ptr)`
internally calls `String::NewFromOneByte` which uses `strlen` to size the V8
string, so:

```
in-binary bytes: l i n u x \0 \0
strlen returns: 5
V8 creates 5-byte JS string: "linux"
process.platform === 'linux'  ✓
```

Critically only **one** standalone `\x00android\x00` literal exists in the
46MB Node binary — verified by counting. The other 11 `android` substring
matches are inside larger tokens (`com.android.tzdata`, `highend_android_phys`,
some V8 error strings) and don't match the null-bounded pattern.

Applied at boot via `patch_node_platform_now` (one-shot) and re-applied on
every `pkg install nodejs` / `pkg upgrade nodejs` via
`install_apt_node_platform_hook` (DPkg::Post-Invoke).

## Why this works

- `process.platform` returns `'linux'` (5 chars exactly, matches JS literal
  `'linux'`).
- npm's optional-dep resolution sees `process.platform === 'linux'`,
  `process.arch === 'arm64'`, picks `@scope/pkg-linux-arm64` correctly.
- Every npm package's `if (process.platform === 'linux')` check takes the
  Linux branch. Including codex's, claude's, future tools'.
- The patch is idempotent: scanning for `\x00android\x00` finds nothing on
  already-patched binaries; the helper exits in milliseconds.

## Failure mode if regressed

- If a Node major bump changes the `OneByteString` call to use
  `NewFromUtf8Literal` (compile-time-known length), the in-binary length
  becomes 7 (= `sizeof("android") - 1`) and our 5-char `linux\x00\x00`
  patch produces a 7-byte JS string `"linux\0\0"` that fails `=== 'linux'`
  comparisons. Mitigation: switch to runtime override (NODE_OPTIONS preload)
  or rebuild Node ourselves.
- If Termux ever ships Node with multiple intern'd `android` literals at
  the call site, our pattern match might be ambiguous. Mitigation: search
  for `\x00android\x00` and assert exactly one match before patching.

## See also

- [npm-intercept.md](npm-intercept.md)
- [deferred-ld-preload-shim.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/deferred-ld-preload-shim.md)
