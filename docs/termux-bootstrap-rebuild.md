# Termux bootstrap rebuilt with our package name

**Status:** Active
**Phase / Commit:** L2a
**Files:** Our termux-packages fork (build host); `crates/gpui_android/examples/zed_android/android/app/src/main/assets/bootstrap-aarch64.zip`

## Problem

Termux's stock bootstrap-aarch64.zip ships every binary with
`/data/data/com.termux/files/usr/...` baked into:

- `DT_RUNPATH` of every dynamically-linked ELF (linker uses these to find
  `.so` deps)
- Shebangs of every shell script (`#!/data/data/com.termux/files/usr/bin/sh`)
- Compiled-in path constants (apt's sysconfdir, gcc's include paths,
  dpkg's status-file location)

Our APK has applicationId `com.zdroid`, so Android places our
files under `/data/data/com.zdroid/files/usr/...`. The com.termux
paths don't exist for our UID — every binary fails at first `dlopen` with
"library not found", every script fails with "no such file or directory" on
the shebang interpreter.

## Constraint

Symlink workarounds don't work — Android sandboxes prevent us writing under
`/data/data/com.termux` (different package, different UID), and even if we
could, the kernel's interpreter lookup at execve time goes through the
SELinux MAC context tied to our package's data dir. Patching every binary
post-extract would be hundreds of patchelf invocations and a maintenance
nightmare.

## Solution

Fork `termux/termux-packages`. Set `TERMUX_APP_PACKAGE=com.zdroid`
in `scripts/properties.sh`. Re-run `scripts/build-bootstraps.sh`. The build
recompiles every package with our app's path baked into its RUNPATH /
shebangs / constants.

Output: a `bootstrap-aarch64.zip` (~25 MB) that extracts cleanly under our
prefix. Pinned release: `bootstrap-2026.02.12-r1+apt.android-7` (sha256
`ea2aeba8819e517db711f8c32369e89e7c52cee73e07930ff91185e1ab93f4f3`) for
reproducibility.

The zip is downloaded by Gradle's `downloadBootstrap` task at build time
(see `android/app/build.gradle.kts`) and bundled as an APK asset. Extracted
on first launch by `crates/gpui_android/src/termux_bootstrap.rs::extract_if_needed`.

## Why this works

- Every ELF's RUNPATH points at `$PREFIX/lib` where its libs actually live.
- Every shebang points at `$PREFIX/bin/sh` which exists.
- Every compiled-in path constant references our prefix.
- The bootstrap is self-contained; no com.termux references survive.

## Failure mode if regressed

- If we ever bump to a new bootstrap release without rebuilding under our
  package name → every binary fails at `dlopen` with `library "libmd.so" not
  found at /data/data/com.termux/...`.
- If `applicationId` in `build.gradle.kts` ever drifts from
  `BOOTSTRAP_PACKAGE_NAME` in our Rust constant → same dlopen failure.
  Guarded by an assert in `examples/zed_android/build.rs` that reads the
  Gradle file and asserts the match at compile time.

## What this leaves open (Layer 3 gap)

When users `pkg install <upstream-package>` from Termux's apt repo at
runtime, those packages still have com.termux baked in. Three layers of
patches address this — see [dpkg-path-rewrite-patches.md](dpkg-path-rewrite-patches.md) and [apt-hooks.md](apt-hooks.md).

## See also

- [dpkg-path-rewrite-patches.md](dpkg-path-rewrite-patches.md)
- [apt-hooks.md](apt-hooks.md)
- [musl-linker-bundle.md](musl-linker-bundle.md)
- [storage-permission-jni.md](storage-permission-jni.md)
