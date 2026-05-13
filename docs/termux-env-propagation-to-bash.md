# Termux env propagation into the integrated terminal

**Status:** Active
**Phase / Commit:** `016378f9e2` — Propagate Termux env into Android integrated-terminal pty
**Files:** `crates/terminal/src/terminal.rs` (`insert_zed_terminal_env`, Android cfg branch)

## Problem

Integrated terminal opened bash, but bash had **no Termux env vars**. PATH
didn't include `$PREFIX/bin`. PREFIX, HOME, TERMUX__HOME — all unset. The
dpkg patches' rewrite logic, the apt hooks' content sed, our maintainer-
script content rewrites, and userspace tools like `pkg`/`apt` themselves
all depend on these. Everything was using stale defaults; package
installation was broken.

## Constraint

`alacritty_terminal::tty::Options.env` **replaces** the inherited env
with the explicit map on Linux (Android compiles as Linux for this branch).
The TERMUX_* / PREFIX / HOME / PATH we set in `lib.rs` via
`std::env::set_var` were sitting in the Rust process's env but invisible
to the bash subprocess because alacritty was building bash's env from
scratch.

`Command::spawn` would inherit by default; alacritty's `tty::unix`
constructs its env explicitly to add ZED_TERM / TERM_PROGRAM / etc., and
in doing so wipes the inheritance.

## Solution

In `insert_zed_terminal_env`, under `#[cfg(target_os = "android")]`, copy
the relevant subset of the Rust process's env into the bash env:

```rust
for key in [
    "TERMUX_APP__PACKAGE_NAME", "TERMUX__PREFIX", "TERMUX__ROOTFS",
    "TERMUX__HOME", "PREFIX", "HOME", "PATH", "TMPDIR", "SHELL", "LANG",
] {
    if let Ok(value) = std::env::var(key) {
        env.entry(key.to_string()).or_insert(value);
    }
}
```

Plus set `LD_PRELOAD = $PREFIX/lib/libtermux-exec.so` (Termux's own
`bin/login` does this — termux-exec hooks libc execve to translate
hardcoded com.termux paths in subprocess invocations).

**Path canonicalization gotcha:** uses `/data/data/<pkg>/...` form, not
Android's resolved `/data/user/0/<pkg>/...` form. Bionic's linker treats
the two as different namespaces; bootstrap binaries' RUNPATH was baked
with `/data/data` form, so LD_PRELOAD also has to be specified that way
for the linker to load libtermux-exec into the same namespace as the
target binary's deps.

## Why this works

- bash and every subprocess it spawns sees the full Termux env. `pkg`,
  `apt`, npm, git, anything called from the terminal: same env as if
  Termux launched it directly.
- LD_PRELOAD libtermux-exec gives us shebang fixups for upstream binaries
  whose interpreter paths still say `/data/data/com.termux/...`.

## Failure mode if regressed

- `pkg install <anything>` fails because PREFIX is unset.
- Subprocess shebangs fail because PATH doesn't include $PREFIX/bin.
- LD_PRELOAD missing → upstream packages with com.termux shebangs fail
  at execve before their preinst can even run.

## Related: terminal HOME override

A subsequent commit (`63ce773f6b`) overrides HOME with TERMUX__HOME for the
terminal subprocess only — see [home-env-dual-pointing.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/home-env-dual-pointing.md)
and [terminal-home-override.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/terminal-home-override.md).

## See also

- [home-env-dual-pointing.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/home-env-dual-pointing.md)
- [terminal-home-override.md](https://github.com/Dylanmurzello/zed-android-port/blob/main/crates/gpui_android/docs/workarounds/terminal-home-override.md)
- [musl-linker-bundle.md](musl-linker-bundle.md)
