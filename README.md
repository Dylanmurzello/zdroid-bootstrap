# zdroid-bootstrap

Termux-flavored userland tarball that the [Zdroid Android port of Zed](https://github.com/Dylanmurzello/zed-android-port) extracts into `$PREFIX` for the **Bootstrap** runtime adapter.

The bootstrap is the rebuilt Termux userland with Zdroid-specific patches baked in:
- `applicationId=com.zdroid` (instead of `com.termux`) — every binary's `DT_RUNPATH` and shebang resolves to our app's data dir
- Patched dpkg / apt for cross-package-name `pkg install`
- Permission fixes for app-private storage exec
- libtermux-exec built with our paths
- apt Pre/Post-Invoke hooks + dpkg path-protect + dpkg/patchelf pins + node platform hook (Phase 8b — see `patches/`)
- musl loader with `/etc/resolv.conf` → `/sdcard/.zed/r` baked in
- npm wrapper + launcher-generator under `.zed/bin/`
- bash-`-l` self-bootstrap shim under `etc/profile.d/`

## Distribution

Releases ship `bootstrap-aarch64.zip` (~241 MB) as a release asset. `BootstrapAdapter::install` in the editor (`crates/zdroid_runtime/src/adapters/bootstrap_install.rs`) hits this repo's `releases/latest` endpoint to pick up the tarball when the user picks Bootstrap in the runtime picker.

Tag naming: `v<termux-bootstrap-version>` (e.g. `v2026.05.06-r3`). The editor stores whatever `tag_name` GitHub returns in `$PREFIX/.bootstrap-version` as the upgrade sentinel.

## Building

Two source inputs:
1. A vanilla `bootstrap-aarch64.zip` produced by the [termux-packages](https://github.com/termux/termux-packages) bootstrap-build with `TERMUX_APP_PACKAGE=com.zdroid`. Built on a Linux runner.
2. The `patches/` directory in this repo — every static file the editor's `apply_runtime_patches` used to drop at first boot. Pure shell / config / one binary blob (musl loader).

Then:

```sh
./build.sh <input vanilla zip> <output zdroid zip>
```

What `build.sh` does:
- Unzips the input.
- Copies `patches/` over the rootfs (preserving 0755 / 0644 modes baked in).
- Runs `perl -i -pe` rewrites of `/data/data/com.termux/` → `/data/data/com.zdroid/` over every dpkg metadata file type (preinst/postinst/prerm/postrm + conffiles + md5sums + list + triggers + templates) and the master status DB. Catches the maintainer-script content gap that the termux-packages CI sed misses for libcompiler-rt + termux-tools.
- Appends a `SYMLINKS.txt` entry for `libc.musl-aarch64.so.1` → `ld-musl-aarch64.so.1` so the editor's extractor replays the alias at unpack time.
- Re-zips.

## Patches directory

| Path | Source | Purpose |
|---|---|---|
| `etc/profile.d/zed-init.sh` | install_profile_d_init | `bash -l` self-bootstrap (PREFIX/PATH/HOME) for sideband shells (run-as, adb, ssh subprocess) |
| `etc/apt/preferences.d/zed-pin-dpkg` | install_apt_dpkg_pin | Pin-Priority 1001 holds for `dpkg` and `patchelf` packages — refuses upstream upgrade that would brick path-rewrite |
| `etc/dpkg/dpkg.cfg.d/zed-protect-libs` | install_dpkg_path_protect | dpkg path-exclude for `libc++_shared.so` — protects our build-time variant from upstream replacement |
| `etc/apt/apt.conf.d/99-zed-rewrite-postinst` | install_apt_rewrite_hook | DPkg::Post-Invoke sed over every metadata file type rewriting com.termux→com.zdroid |
| `etc/apt/apt.conf.d/98-zed-patchelf` + `etc/apt/zed-patchelf-hook.sh` | install_apt_patchelf_hook | patchelf-set-rpath + perl-hex-patch on freshly-installed ELFs (handles upstream binaries with com.termux DT_RUNPATH + rodata) |
| `etc/apt/apt.conf.d/97-zed-pre-install` + `etc/apt/zed-pre-install-rewrite.sh` | install_apt_pre_install_hook | Reads .deb stdin, unpacks, rewrites com.termux→com.zdroid in text files, repacks |
| `etc/apt/apt.conf.d/97-zed-node-platform` + `etc/apt/zed-node-platform-hook.sh` | install_apt_node_platform_hook | perl rewrites `\x00android\x00` → `\x00linux\x00\x00` in `$PREFIX/bin/node` so `process.platform === 'linux'` |
| `.zed/bin/npm` | install_npm_wrapper | PATH-precedence wrapper setting LD_PRELOAD=libtermux-exec.so + npm_config_libc=musl, post-invokes launcher generator |
| `etc/apt/zed-launcher-gen.sh` | install_npm_launcher_generator | Walks `$PREFIX/bin/*` and `$PREFIX/lib/node_modules/**`, classifies ld-musl vs ld-linux, generates musl-static + grun wrappers |
| `lib/ld-musl-aarch64.so.1` | install_musl_linker | Alpine's musl loader with the `/etc/resolv.conf` → `/sdcard/.zed/r` resolv.conf path hex-patched in (Bun-compiled CLIs route DNS through our materialized resolv file) |

See `docs-extraction-notes.md` for the original Rust source-line mapping per file.

## History

Pre-Phase-6 of the Termux-divestment refactor, the zip lived under [Dylanmurzello/zed-android-port releases](https://github.com/Dylanmurzello/zed-android-port/releases) (`bootstrap-2026.05.06-r2` and earlier). Phase 6 moved distribution here. Phase 8a deleted the editor-side APK-asset extraction path. Phase 8b moved the runtime patches into `patches/` here so the zip ships pre-patched; the editor's `apply_runtime_patches` Rust path is then redundant.
