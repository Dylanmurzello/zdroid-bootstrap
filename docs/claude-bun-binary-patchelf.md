# Claude Bun-binary patchelf + proot wrapper (superseded)

**Status:** Superseded by [hex-patch-resolv-conf.md](hex-patch-resolv-conf.md) +
[npm-intercept.md](npm-intercept.md). Kept here for archaeology — the
historical claude-specific path explains why we even needed the wrapper
machinery, and what symptoms tell you a regression has dragged us back
toward this shape.
**Phase / Commit:** Phase 8 / L2g (commits since reverted: see L4e
`544ec57e85`, then L4g `ce613cb8fe`)
**Files (original — now removed):** `crates/gpui_android/src/termux_bootstrap.rs::install_claude_setup_script`, `auto_fix_claude_if_broken`

## Problem

`claude` from `@anthropic-ai/claude-code`:

1. Ships a JS stub at `bin/claude.exe` that throws "native binary not
   installed" because the optional dep dir layout doesn't match what its
   `install.cjs` expected.
2. The actual binary in the optional dep `@anthropic-ai/claude-code-linux-
   arm64-musl/claude` is a Bun-compiled binary with `INTERP=/lib/ld-musl-
   aarch64.so.1` (a path Android doesn't have) and hardcoded `/etc/resolv.
   conf` for DNS.

Without intervention: claude can't find the optional dep, can't load the
musl interpreter, can't resolve DNS. Three failure modes.

## Constraint

- Bun statically links musl libc into the produced binary. **LD_PRELOAD
  cannot intercept** statically-linked libc calls — they go direct to syscall
  with no PLT/GOT for our preload to override.
- We don't control Bun's distribution; can't ship a different binary.
- `/etc/resolv.conf` is read by Bun's DNS resolver before any application
  code runs; can't shim with env vars.

## Solution

`zed-setup-claude` script written at boot and auto-run when claude.exe is
detected as the small JS stub:

1. `npm install -g --force @anthropic-ai/claude-code-linux-arm64-musl` —
   forces a fresh download of the optional dep (with our NODE_PLATFORM patch
   active, this is no longer strictly needed but kept defensively).
2. `cp $MUSL_PKG_DIR/claude $PREFIX/lib/node_modules/@anthropic-ai/claude-
   code/bin/claude.exe` — copies the actual binary into where the JS stub
   lives, so when `claude.exe` is exec'd it's the real binary not the stub.
3. `patchelf --set-interpreter $PREFIX/lib/ld-musl-aarch64.so.1 claude.exe`
   — points the Bun-baked `/lib/...` interpreter path at our shipped musl
   linker.
4. `patchelf --set-rpath $PREFIX/lib claude.exe` — RUNPATH for any DT_NEEDED
   entries (Bun usually has none, defensive).
5. Writes `$PREFIX/bin/claude` wrapper:
   ```sh
   exec env -u LD_PRELOAD $PREFIX/bin/proot \
        -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        $PREFIX/lib/node_modules/.../claude.exe "$@"
   ```
   - `env -u LD_PRELOAD`: removes Termux's `libtermux-exec.so` from
     LD_PRELOAD because that lib is bionic-linked and loading it into a
     musl process fails with symbol-not-found.
   - `proot -b /etc/resolv.conf:/etc/resolv.conf`: ptrace-based
     bind-mount of our `$PREFIX/etc/resolv.conf` over the literal path
     `/etc/resolv.conf` that Bun reads.

## Why this works

- patchelf gives the kernel a valid interpreter path it can actually exec.
- proot's syscall interception catches Bun's static-linkage `open(/etc/
  resolv.conf)` (the only thing that catches it on a non-rooted device) and
  rewrites to our path.
- env -u LD_PRELOAD ensures we don't poison the Bun process with bionic libs.

## Failure mode if regressed

- patchelf step omitted → kernel-level "ENOENT: no such file or
  directory" on the interpreter at exec time.
- proot wrapper omitted → claude starts but DNS resolution fails silently
  on first network call.
- env -u LD_PRELOAD omitted → process exits with libtermux-exec
  symbol-not-found errors before it even runs.

## What replaced this

The combo of L4f (JNI DNS bridge) + L4g (hex-patch /etc/resolv.conf):
the binary's `.rodata` is patched to read from `/sdcard/.zed/r`
instead of `/etc/resolv.conf`, and a tiny env-strip wrapper at
`$PREFIX/bin/<name>` strips LD_PRELOAD before exec. No proot, no JS
dispatcher round-trip, no per-tool zed-setup-claude script.

The same machinery picks up codex and any future Bun-compiled npm CLI
without per-tool effort — the launcher generator's deep-walk
classifier finds the binary, hex-patches it, writes the env-strip
wrapper. The dead code (`install_claude_setup_script`,
`auto_fix_claude_if_broken`) was removed.

## See also

- [hex-patch-resolv-conf.md](hex-patch-resolv-conf.md) — the
  replacement
- [jni-dns-bridge.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/jni-dns-bridge.md)
- [sdcard-dot-zed-namespace.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/sdcard-dot-zed-namespace.md)
- [npm-intercept.md](npm-intercept.md)
- [node-platform-patch.md](node-platform-patch.md)
- [musl-linker-bundle.md](musl-linker-bundle.md)
