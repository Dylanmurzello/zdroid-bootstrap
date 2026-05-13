# Protect baseline libs from patchelf + dpkg corruption

**Status:** Active

The bootstrap zip ships `lib/libc++_shared.so` and the APK ships `lib/ld-musl-aarch64.so.1` as separate assets. Both are baseline runtime libs that the rest of `$PREFIX` is linked against. Two boot-flow side-effects can corrupt them; both are fenced off now.

## Symptom

After running an `apt --fix-broken install` that pulls in C++/Rust toolchain packages (clang, libllvm, lld, llvm, ndk-sysroot, libcompiler-rt, rust-src), `libc++_shared.so` grows from 1374336 to 1555753 bytes and `ld-musl-aarch64.so.1` grows from 723480 to 812817. Every subsequent invocation of:

- `apt` (its libapt-pkg loads the corrupted libstdc++ chain)
- `patchelf` (links against libc++_shared.so itself)
- `claude` (Bun-compiled musl-static; loads ld-musl, then libstdc++ via apt's chain)

segfaults at `0x1423c0` on the first PLT trampoline. Recovery without the protections below required uninstalling the app to wipe `$PREFIX` and re-extract from the APK.

## Primary fix: patchelf skip-list in the apt Post-Invoke hook

`apply_runtime_patches` writes `$PREFIX/etc/apt/zed-patchelf-hook.sh` with the following early-return in `maybe_patchelf`:

```sh
case "${1##*/}" in
    ld-musl-aarch64.so.1|libc.musl-aarch64.so.1|libc++_shared.so) return 0 ;;
esac
```

`patchelf --set-rpath` grows ELF files by ~12% to add an RPATH section + adjust the program header table. Doing that to the dynamic linker (`ld-musl-aarch64.so.1`) is meaningless — the dynamic linker doesn't read its own RPATH — and doing it to `libc++_shared.so` shifts section table offsets in ways that break `libapt-pkg`'s libstdc++ symbol resolution on the next invocation, breaking apt + everything that uses libstdc++ via apt-resolved deps.

The hook fires after every `apt install` because the bootstrap ships these files with `ctime` matching extract time, the `find … -cmin -10 -name '*.so*'` predicate matches them, and `maybe_patchelf` originally had no exclusion list. Skip-list returns early on basename match.

**Subtle prerequisite:** the case statement uses shell parameter expansion `${1##*/}` rather than `$(basename -- "$1")`, because the helper body is generated from a Rust `format!(...)` string and over-escaping the inner quotes (`\\\"$1\\\"` → rendered as `\"$1\"`) makes shell pass a literal-with-quotes argument to basename, returning a junk value that never matches the case patterns. The skip-list never fires in that form. **Always render and grep the actual on-disk script when changing this file.** See commit `d1a6319256` for the original break and fix.

## Defense in depth: dpkg path-exclude

`apply_runtime_patches` also writes `$PREFIX/etc/dpkg/dpkg.cfg.d/zed-protect-libs`:

```
path-exclude=/data/data/com.zdroid/files/usr/lib/libc++_shared.so
```

This makes dpkg refuse to extract that exact path from any package. The Termux apt repository's `libc++` package ships its own `libc++_shared.so`; if a future apt run upgrades libc++ as a transitive dep, the path-exclude prevents the on-disk file from being replaced. **In practice this never fires on the current Termux package set** — `apt --fix-broken install` after `apt install rust` does not pull libc++ as a new install — but it's a cheap insurance policy against the failure mode coming back via a future package metadata change.

## Verifying

After any `apt install` operation, both files should remain at their in-zip / extract-time values:

```sh
sha256sum $PREFIX/lib/libc++_shared.so $PREFIX/lib/ld-musl-aarch64.so.1
# expect:
# e09c2f45cf4cf8ae574f94b6c2650d99ead0d332d5396f6613f062a2d2d73540  libc++_shared.so   (size 1374336)
# 128c50e773c0f62d8b136287314f61f00753f2d7df0fdc39d44a2fbcf0e64b75  ld-musl-aarch64.so.1  (size 723480)
```

If either grows by ~12%, the patchelf hook's skip-list isn't firing — first thing to check is the rendered `$PREFIX/etc/apt/zed-patchelf-hook.sh` for the `case "${1##*/}" in` line, since shell-quoting bugs in the Rust generator are how this regressed once before.
