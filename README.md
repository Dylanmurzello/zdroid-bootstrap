# zdroid-bootstrap

Termux-flavored userland tarball that the [Zdroid Android port of Zed](https://github.com/Dylanmurzello/zed-android-port) extracts into `$PREFIX` for the **Bootstrap** runtime adapter.

The bootstrap is the rebuilt Termux userland with Zdroid-specific patches baked in:
- `applicationId=com.zdroid` (instead of `com.termux`) so every binary's `DT_RUNPATH` and shebangs resolve to our app's data dir
- Patched dpkg / apt for cross-package-name `pkg install`
- Permission fixes for app-private storage exec
- libtermux-exec build with our paths

## Distribution

Releases ship `bootstrap-aarch64.zip` (~239 MB) as a release asset. `BootstrapAdapter::install` in the editor (`crates/zdroid_runtime/src/adapters/bootstrap_install.rs`) hits this repo's `releases/latest` endpoint to pick up the tarball when the user picks Bootstrap in the runtime picker.

Tag naming: `v<termux-bootstrap-version>` (e.g. `v2026.05.06-r2`). The editor stores whatever `tag_name` GitHub returns in `$PREFIX/.bootstrap-version` as the upgrade sentinel.

## History

Pre-Phase-6 of the Termux-divestment refactor, the zip lived under [Dylanmurzello/zed-android-port releases](https://github.com/Dylanmurzello/zed-android-port/releases) (`bootstrap-2026.05.06-r2` and earlier). Phase 6 moved distribution here so the APK no longer needs to bundle 240 MB.

## Building

The bootstrap is produced by the [termux-packages](https://github.com/termux/termux-packages) bootstrap-build pipeline with `TERMUX_APP_PACKAGE=com.zdroid`. Build scripts and the patch set will land in this repo as a follow-up (`build/` directory). Until then, build artifacts only.
