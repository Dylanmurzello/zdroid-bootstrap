# npm intercept stack (wrapper + launcher generator)

**Status:** Active
**Phase / Commit:** L4 npm intercept
**Files:** `crates/gpui_android/src/termux_bootstrap.rs` (`install_npm_wrapper`, `install_npm_launcher_generator`)

## Problem

Each npm-distributed CLI we wanted to support — claude first, then codex,
inevitably more later — needed its own bespoke `zed-setup-X` script that:
force-installed the Linux variant, copied the native binary into the right
spot, patchelf'd the interpreter, wrote a wrapper that did `proot -b
/etc/resolv.conf`. The same five-step dance per tool. Per-tool patches don't
scale; they rot when upstream changes packaging.

## Constraint

npm doesn't have a global post-install hook. `package.json`'s `scripts.
postinstall` is per-package. We don't control upstream tool publishers'
package.json files. So the only place we can hook generically is npm itself.

## Solution

Two pieces, both written by `termux_bootstrap.rs::apply_runtime_patches`:

### 1. `$PREFIX/bin/npm` shell shim

Replaces the upstream symlink → `npm-cli.js` with a 20-line shell wrapper:

```sh
"$NODE" "$REAL_NPM_JS" "$@"
RC=$?
[ -x "$HOOK" ] && "$HOOK" 2>&1 || true
exit $RC
```

Forwards argv verbatim, preserves exit code, fires the launcher generator on
every npm op. Self-healing — re-installed by `apply_runtime_patches` on every
boot in case `pkg install nodejs` or `npm install -g npm` clobbers the
symlink.

### 2. `$PREFIX/etc/apt/zed-launcher-gen.sh` — the classifier + generator

Walks `$PREFIX/bin/*` symlinks resolving into `$PREFIX/lib/node_modules/`,
classifies each ELF target by interpreter and content, and writes the right
runtime wrapper at the symlink path:

| Detection | Wrapper |
|---|---|
| Not ELF (script) | leave npm's symlink alone |
| `INTERP = /lib/ld-musl-aarch64.so.1` | `patchelf --set-interpreter $PREFIX/lib/ld-musl-aarch64.so.1`, then either passthrough (npm symlink) or proot wrapper if hardcoded /etc/resolv.conf |
| `INTERP = /lib/ld-linux-aarch64.so.1` (glibc) | `grun` wrapper if installed; else stub with install instructions |
| Static or no INTERP, hardcoded /etc/resolv.conf | proot wrapper |
| Static or no INTERP, no hardcoded paths | leave npm's symlink alone |

`grep -q -a -- '/etc/resolv.conf' $bin` is the hardcoded-path detection.
proot is the chosen wrapper (vs LD_PRELOAD shim) for static binaries because
LD_PRELOAD can't intercept syscalls in statically-linked libc.

## Why this works

- `npm install -g <new-tool>`:
  1. Our wrapper forwards to real npm
  2. real npm creates `$PREFIX/bin/<new-tool>` symlink → `node_modules/<pkg>/bin/<entry>`
  3. Wrapper exit triggers the generator
  4. Generator inspects the target, picks the right wrapper
  5. User runs `<new-tool>` and it executes through the appropriate runtime

- Idempotent: re-running on unchanged state is free (content compare per
  generated wrapper body).

- Composable: every layer is a separate concern with a single hook point.
  Adding a new ELF type later (e.g. PIE-only binaries needing different
  patchelf) means one new case in the shell `case` statement.

## Failure mode if regressed

- npm wrapper missing or broken → npm itself stops working in the terminal.
  Mitigation: shim is plain forwarding shell with the post-hook gated behind
  `[ -x "$HOOK" ]`; broken hook can never break npm proper.
- Generator misclassifies → wrong runtime wrapper, tool fails on first run
  with a specific error. Symptom: `cannot execute` or `library not found`
  on the affected tool. Re-running the generator after fixing the
  classification rule (idempotent) fixes it.
- `pkg upgrade nodejs` clobbers the npm symlink → wrapper missing →
  apply_runtime_patches re-installs at next app boot.

## What this kills

- `zed-setup-claude` script's patchelf/proot logic (claude becomes "just
  another npm install" once we extend the generator to walk node_modules
  recursively for the optional-dep binary).
- The hypothetical `zed-setup-codex`, `zed-setup-anything-else`.
- Future per-tool `zed-setup-X` work.

## What this doesn't kill

- The Node `NODE_PLATFORM` patch — that's the foundation. Without it npm
  never resolves `linux-arm64` optional deps to begin with. See
  [node-platform-patch.md](node-platform-patch.md).
- glibc-runner setup — still a one-time `pkg install tur-repo glibc-runner`
  for glibc-only tools (rare in the AI-CLI space; most are Bun-compiled).

## See also

- [node-platform-patch.md](node-platform-patch.md)
- [claude-bun-binary-patchelf.md](claude-bun-binary-patchelf.md)
- [musl-linker-bundle.md](musl-linker-bundle.md)
- [deferred-ld-preload-shim.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/deferred-ld-preload-shim.md)
