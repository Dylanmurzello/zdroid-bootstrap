# termux_bootstrap.rs static-file extraction notes

Source: `/Users/dylanmurzello/Developer/zed_port/zed/crates/gpui_android/src/termux_bootstrap.rs`

Path substitutions used (all interpolations resolve to these):
- `prefix` / `$PREFIX` / `prefix_str` → `/data/data/com.zdroid/files/usr`
- `data_path` / `rootfs_str` → `/data/data/com.zdroid/files`
- `info` (dpkg info dir) → `/data/data/com.zdroid/files/usr/var/lib/dpkg/info`
- `status` (dpkg status file) → `/data/data/com.zdroid/files/usr/var/lib/dpkg/status`

## Files written

| Path (under `/tmp/zdroid-bootstrap-work/patches/`) | Source fn | Mode | Description |
|---|---|---|---|
| `etc/profile.d/zed-init.sh` | `install_profile_d_init` (line 98) | 0644 | bash -l self-bootstrap shim: sets PREFIX, TERMUX__PREFIX, TERMUX__ROOTFS, HOME, TMPDIR, LANG, PATH (incl. .zed/bin precedence) when parent env lacks them. (already existed, content verified to match) |
| `etc/apt/preferences.d/zed-pin-dpkg` | `install_apt_dpkg_pin` (line 1049) | 0644 | Pin-Priority 1001 holds for `dpkg` and `patchelf` packages. apt_preferences(5) syntax (`#` comments, not `//`). (already existed, content verified to match) |
| `etc/dpkg/dpkg.cfg.d/zed-protect-libs` | `install_dpkg_path_protect` (line 1119) | 0644 | `path-exclude=/data/data/com.zdroid/files/usr/lib/libc++_shared.so` — dpkg refuses to extract libc++_shared.so from any package. |
| `etc/apt/apt.conf.d/99-zed-rewrite-postinst` | `install_apt_rewrite_hook` (line 1260) | 0644 | DPkg::Post-Invoke sed hook rewriting com.termux→com.zdroid in dpkg metadata files (preinst/postinst/prerm/postrm/conffiles/md5sums/list/triggers/templates) plus master status DB. |
| `etc/apt/apt.conf.d/98-zed-patchelf` | `install_apt_patchelf_hook` (line 1356) conf | 0644 | DPkg::Post-Invoke pointer to `etc/apt/zed-patchelf-hook.sh`. |
| `etc/apt/zed-patchelf-hook.sh` | `install_apt_patchelf_hook` (line 1356) helper | 0755 | Walks recently-ctime'd files in $PREFIX/{bin,sbin,libexec,lib} (+ glibc variants), patchelf-set-rpath to $PREFIX/lib (with skip list for ld-musl/libc++_shared/libc.musl), perl-hex-patch com.termux→com.zdroid and /etc/resolv.conf→/sdcard/.zed/r in rodata. |
| `etc/apt/apt.conf.d/97-zed-pre-install` | `install_apt_pre_install_hook` (line 924) conf | 0644 | DPkg::Pre-Install-Pkgs pointer to `etc/apt/zed-pre-install-rewrite.sh`. |
| `etc/apt/zed-pre-install-rewrite.sh` | `install_apt_pre_install_hook` (line 924) helper | 0755 | Reads .deb paths from stdin, dpkg-deb -R extracts each, sed-rewrites com.termux→com.zdroid in any text files (incl. shebangs in DEBIAN/{preinst,postinst,prerm,postrm} and data-archive scripts), dpkg-deb -b rebuilds. |
| `etc/apt/apt.conf.d/97-zed-node-platform` | `install_apt_node_platform_hook` (line 817) conf | 0644 | DPkg::Post-Invoke pointer to `etc/apt/zed-node-platform-hook.sh`. |
| `etc/apt/zed-node-platform-hook.sh` | `install_apt_node_platform_hook` (line 817) helper | 0755 | perl in-place rewrites \x00android\x00 → \x00linux\x00\x00 in $PREFIX/bin/node so process.platform === 'linux'. |
| `.zed/bin/npm` | `install_npm_wrapper` (line 442) | 0755 | PATH-precedence wrapper that sets LD_PRELOAD=libtermux-exec.so and npm_config_libc=musl, then forks node $PREFIX/lib/node_modules/npm/bin/npm-cli.js, then invokes `etc/apt/zed-launcher-gen.sh`. |
| `etc/apt/zed-launcher-gen.sh` | `install_npm_launcher_generator` (line 568) | 0755 | Walks $PREFIX/bin/* symlinks resolving into $PREFIX/lib/node_modules and any $PREFIX/lib/node_modules/** ELF; classifies ld-musl-aarch64/ld-linux-* interp; patchelf interp + rpath fix, perl resolv.conf hex-patch, writes env-strip wrapper for musl-static and grun wrapper (or install-instruction stub) for glibc-dynamic. |

Twelve files total. Two pre-existing matched the regenerated content; the other ten were freshly extracted.

## Functions skipped (per task brief)

- `install_musl_linker` (line 1541) — binary APK-asset blob copy + symlink + in-memory `patch_resolv_conf_in_bytes` rewrite on $PREFIX/lib/ld-musl-aarch64.so.1. Not extractable as a static text file.
- `rewrite_maintainer_scripts` (line 1184) — mutates existing $PREFIX/var/lib/dpkg/info/*.{preinst,postinst,prerm,postrm,conffiles,md5sums,list,triggers,templates} + status. Runtime in-place rewrite.
- `rewrite_one_script` (line 1236) — helper of rewrite_maintainer_scripts.
- `patch_node_platform_now` (line 767) — runtime in-place rewrite of $PREFIX/bin/node.
- `run_launcher_generator` (line 217) — spawns the already-installed helper at boot.
- `cleanup_legacy_claude_wrapper` (line 257) — runtime cleanup of stale .real chains and Auto-generated wrappers under $PREFIX/lib/node_modules.
- `apply_runtime_patches` (line 53) — orchestrator that calls all install_*.
- `check_selinux_context` (line 1615) — runtime diagnostic log line.
- `patch_resolv_conf_in_bytes` (line 1591) — pure-Rust byte-array helper used by install_musl_linker.
- `bootstrap_command` (line 199) — Command builder helper.

## Interpolations covered, gotchas to flag

All Rust-side interpolations encountered were satisfied by the brief's hardcoded substitution table:
- `{prefix}` / `{prefix_str}` → `/data/data/com.zdroid/files/usr` (every install fn computes `prefix_str` via the `/data/user/0/<pkg>` → `/data/data/<pkg>` rewrite; result is the canonical $PREFIX).
- `{rootfs_str}` (only in `install_profile_d_init`) → `/data/data/com.zdroid/files`.
- `{info}` / `{status}` (only in `install_apt_rewrite_hook`) → expanded to absolute paths.
- `{helper_path}` (in node-platform, pre-install, patchelf conf bodies) → expanded `prefix.join("etc/apt/<helper>.sh").display()`.

No additional substitution domains encountered.

## Subtleties worth knowing

1. **`{{` / `}}` collapse in `format!()`**: Rust raw braces in format strings escape as `{{`/`}}`. Every shell function open (`name() {{`), case-block (`case ... in`/`esac` neighborhood), perl regex `m{...}`, perl `do { local $/; <$fh> }`, and apt-conf `DPkg::Post-Invoke {{ ... }}` collapses to single `{`/`}` in the file.

2. **`\n\` line continuation eats source indent**: After `\n\`, the next source line's leading whitespace is consumed; the indent in the FILE is determined by what comes BEFORE the `\n` (e.g. `\n    \` lands 4 spaces in the file then eats source ws). Many helper scripts use this aggressively — column-0 headers, 4-space function body, 8-12-16 nested indent. The `etc/apt/zed-launcher-gen.sh` is the densest example.

3. **Multi-line shell variable assignments embed literal newlines**: `want="#!$PREFIX/bin/sh\n` followed by `exec ...\""` puts a real newline inside the `$want` value. The subsequent `printf '%s\n' "$want" > "$dst"` writes the value as multi-line file content. Don't be confused by `exec`/`echo` lines that look unindented in the helper — they're literal-string interior, not code-flow.

4. **Backslash counting differs across hook layers**:
   - In shell scripts (`.sh` files): Rust `\\.` (4 chars source) → file `\.` (2 chars) → sed/grep sees `\.` correctly escaping the dot.
   - In apt.conf files: Rust `\\\\.` (6 chars source) → file `\\.` (3 chars) → apt's quoted-string parser strips one `\` → shell sees `\.` → sed receives `\.`. This is why `install_apt_rewrite_hook` has `\\\\.` in its source while `install_apt_pre_install_hook`'s helper has plain `\\.`.

5. **Perl hex-patch blocks are single Rust source lines**: e.g. line 1459 of `install_apt_patchelf_hook` and line 649 of `install_npm_launcher_generator` contain literal `\n`s that produce a multi-line perl source with 16-/20-space indents preserved as written. Don't try to fold those indents to canonical 4-space — they're what the source ships.

6. **Two `97-` apt.conf hooks**: `97-zed-pre-install` (Pre-Install-Pkgs) and `97-zed-node-platform` (Post-Invoke). Same lexical prefix; apt fires them at different lifecycle points so ordering between them doesn't matter.

## Verification

All extracted shell scripts pass `sh -n` syntax check. Permissions set per Rust source: configs 0644, shell scripts 0755.
