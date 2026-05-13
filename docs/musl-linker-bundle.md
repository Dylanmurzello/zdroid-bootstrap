# Musl-aarch64 linker bundled in APK

**Status:** Active
**Phase / Commit:** Initial bundle + later libc resolv.conf hex-patch
**Files:** `crates/gpui_android/src/termux_bootstrap.rs::install_musl_linker`

## Problem

Bun-compiled CLIs (claude, codex, every static-musl tool we install
via `npm install -g`) ship with `INTERP=/lib/ld-musl-aarch64.so.1` in
their ELF program header. Android has no `/lib` (the closest the OS
provides is `/system/lib64`, with bionic's loader at
`/system/bin/linker64`), so execve fails immediately with `ENOENT` on
the interpreter.

We can't symlink `/lib/ld-musl-aarch64.so.1 → /system/bin/linker64`:
the linker ABIs are incompatible (musl's loader expects musl ELF, not
bionic), and even if they were, `/lib` is on the read-only system
partition and we can't write there.

## Solution

Bundle Alpine's `ld-musl-aarch64.so.1` (~723 KB, extracted from
`musl-1.2.5-r23.apk` at build time) as an APK asset. At boot,
`install_musl_linker`:

1. Reads the asset bytes.
2. **Hex-patches the in-memory bytes** to rewrite the literal
   `/etc/resolv.conf` (16 bytes) to `/sdcard/.zed/r` (14 bytes + 2 NUL
   pad = same 16-byte slot width). See "The libc resolv.conf leak"
   below for why this is critical.
3. Writes the patched bytes to `$PREFIX/lib/ld-musl-aarch64.so.1`.
4. Creates a `$PREFIX/lib/libc.musl-aarch64.so.1` symlink — in musl,
   the dynamic linker IS libc, so the same file serves both DT_INTERP
   and DT_NEEDED libc lookups.

The launcher generator's `--set-interpreter` patchelf pass then
rewrites Bun-compiled binaries to point at our prefixed path
(`$PREFIX/lib/ld-musl-aarch64.so.1` instead of the unreachable
`/lib/ld-musl-aarch64.so.1`). After both passes, the binary loads,
the loader becomes its libc at runtime, and it runs natively.

## The libc resolv.conf leak (why step 2 matters)

The launcher-gen's perl block hex-patches `/etc/resolv.conf →
/sdcard/.zed/r` in every executable that has the literal in its
`.rodata`. That covers Bun-compiled binaries' statically-linked
c-ares — claude's main binary, etc.

But Bun's HTTP/fetch layer doesn't only call into the static c-ares.
It also reaches `getaddrinfo()` through the **dynamically-loaded musl
libc** (`libc.musl-aarch64.so.1` here). musl's `getaddrinfo` calls
`__resolvconf` which has its OWN baked-in `/etc/resolv.conf` literal,
and that literal lives in the libc, not in the main binary. The
launcher-gen pass patches binaries; it doesn't walk shared libraries.

**Concrete bite, 2026-05-06:** claude's main binary was hex-patched
correctly (verified via `strings | grep -c /etc/resolv.conf` → 0).
Yet `claude --print "hi"` (with a fake API key to force the network
attempt) hit `ECONNREFUSED`. Strace caught it:

```
openat("/etc/resolv.conf", O_RDONLY) = -1 ENOENT
sendto(16, ...api.anthropic.com..., port=53, addr=127.0.0.1) = 35
connect(16, sin_port=65535, sin_addr=127.0.0.1) = 0
... claude reports: API Error: Unable to connect to API (ConnectionRefused)
```

The `openat("/etc/resolv.conf")` was happening from musl libc, not
from the main binary. `strings $PREFIX/lib/libc.musl-aarch64.so.1 |
grep -c /etc/resolv.conf` → 1. That was the leak.

The fix is to apply the same hex-patch on the libc asset bytes
before we write them out. Done once at boot in
`install_musl_linker`, idempotent across reboots (every run rewrites
from the APK asset). One log line confirms it:
`installed musl linker (723480 bytes) at ... (resolv.conf
hex-patches applied: 1)`.

## Why this works

- Same byte-width substitution as the launcher-gen perl pass — 16
  byte slot, NUL-bounded, `strlen`-safe.
- Lives in install code, not runtime — no ongoing cost, just a
  ~700 KB byte scan once per boot.
- Closes the leak class for **every** Bun-musl binary, current and
  future. claude, codex, any new tool whose Bun runtime ends up
  calling musl's getaddrinfo — they all read `/sdcard/.zed/r` via
  this libc, populated by `dns_bridge` from Android's actual DNS.

## Failure modes if regressed

- `install_musl_linker` skipped or failed → no `ld-musl-aarch64.so.1`
  in `$PREFIX/lib`, every musl-INTERP binary fails at execve with
  `ENOENT`.
- Hex-patch removed → `installed musl linker ... resolv.conf
  hex-patches applied: 0` in logcat. Every Bun-compiled CLI's HTTP
  fetch falls back to `127.0.0.1:53`, gets `ECONNREFUSED` on first
  network call.
- Asset bytes shape change (Alpine bumps musl version, literal moves
  in `.rodata`) → patch count drops to 0, fix silently inactive.
  Logcat catches it via the patch-count line; CI guard would be
  reading `strings $PREFIX/lib/libc.musl-aarch64.so.1 | grep -c
  /etc/resolv.conf` post-extract and asserting 0.

## See also

- [hex-patch-resolv-conf.md](hex-patch-resolv-conf.md) — the main-
  binary side of the same strategy
- [jni-dns-bridge.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/jni-dns-bridge.md) — what populates
  `/sdcard/.zed/r` with real nameservers
- [sdcard-dot-zed-namespace.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/sdcard-dot-zed-namespace.md) — why
  `/sdcard/.zed/r` and not app-private
- [npm-intercept.md](npm-intercept.md) — the launcher-gen
  infrastructure that handles per-binary patching
