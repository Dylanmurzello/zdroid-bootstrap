#!/usr/bin/env bash
# Rebuild bootstrap-aarch64.zip with all Zdroid runtime patches baked
# in. Source: an upstream termux-packages bootstrap (already built
# with `TERMUX_APP_PACKAGE=com.zdroid` so binaries' DT_RUNPATH +
# shebangs point at /data/data/com.zdroid/...) — we only need to
# overlay the apt/dpkg/npm/profile.d scripts that termux_bootstrap.rs
# used to write at first boot.
#
# Usage: ./build.sh <input zip> <output zip>
#
# Layout:
#   patches/         — every file the editor used to write at boot.
#                      Mirrors `$PREFIX/<rel>` layout. Permissions
#                      preserved when copied over the staging rootfs.
#   patches/lib/ld-musl-aarch64.so.1 — the resolv.conf-hex-patched
#                      musl loader. Symlink alias added at zip-pack
#                      time below.
#
# What we do that termux_bootstrap.rs used to do at boot:
#   1. cp -a patches/* into the rootfs.
#   2. sed -i 's|/data/data/com.termux/|/data/data/com.zdroid/|g' over
#      every dpkg metadata file type (maintainer scripts, conffiles,
#      md5sums, list, triggers, templates) + the master status DB.
#      Length-preserving byte substitution (22==22) so file offsets
#      don't shift.
#   3. Add SYMLINKS.txt entry for libc.musl-aarch64.so.1 → ld-musl-
#      aarch64.so.1 so the editor-side extractor replays it on extract.
#   4. Re-zip preserving permissions.

set -euo pipefail

IN_ZIP="${1:?usage: $0 <input zip> <output zip>}"
OUT_ZIP="${2:?usage: $0 <input zip> <output zip>}"

if [ ! -f "$IN_ZIP" ]; then
    echo "input zip not found: $IN_ZIP" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES="$SCRIPT_DIR/patches"
if [ ! -d "$PATCHES" ]; then
    echo "patches/ dir missing: $PATCHES" >&2
    exit 1
fi

WORK="$(mktemp -d -t zdroid-bootstrap-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "build: workspace = $WORK"

ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"

echo "build: unzipping $IN_ZIP"
unzip -q "$IN_ZIP" -d "$ROOTFS"

echo "build: copying patches"
cp -a "$PATCHES"/. "$ROOTFS"/

# rewrite_maintainer_scripts equivalent. The bootstrap built by termux-
# packages CI with TERMUX_APP_PACKAGE=com.zdroid already has com.zdroid
# paths in binaries' RUNPATH + most files. But dpkg maintainer scripts
# (preinst/postinst/prerm/postrm) and metadata files (conffiles, list,
# md5sums, etc.) for libcompiler-rt + termux-tools were observed to
# still carry com.termux strings (build pipeline misses them — see r5
# comments in the legacy termux_bootstrap.rs). Sed catches them.
INFO="$ROOTFS/var/lib/dpkg/info"
STATUS="$ROOTFS/var/lib/dpkg/status"
if [ -d "$INFO" ]; then
    echo "build: rewriting com.termux references in dpkg metadata"
    # `-print -quit` first to avoid no-match noise; then sed in place.
    # Using perl -i -pe instead of sed -i for BSD/GNU portability —
    # macOS sed needs `-i ''` and silently misinterprets paths as the
    # backup suffix without it, GNU sed accepts bare `-i`. perl works
    # the same on both.
    for ext in preinst postinst prerm postrm conffiles md5sums list triggers templates; do
        find "$INFO" -maxdepth 1 -name "*.${ext}" -print0 2>/dev/null \
            | xargs -0 -r perl -i -pe 's|/data/data/com\.termux/|/data/data/com.zdroid/|g' || true
    done
    if [ -f "$STATUS" ]; then
        perl -i -pe 's|/data/data/com\.termux/|/data/data/com.zdroid/|g' "$STATUS"
    fi
fi

# Add the libc.musl-aarch64.so.1 → ld-musl-aarch64.so.1 alias via
# SYMLINKS.txt. The delimiter is U+2190 LEFTWARDS ARROW (UTF-8 bytes
# e2 86 90); the line format is `<absolute-target>←<relative-link>`.
# Editor-side `zdroid_runtime::adapters::bootstrap_install::
# extract_entries` replays this entry at extract time.
SYMLINKS_TXT="$ROOTFS/SYMLINKS.txt"
ALIAS_LINE='/data/data/com.zdroid/files/usr/lib/ld-musl-aarch64.so.1'$'\xe2\x86\x90''./lib/libc.musl-aarch64.so.1'
if ! grep -Fxq "$ALIAS_LINE" "$SYMLINKS_TXT" 2>/dev/null; then
    echo "build: adding libc.musl-aarch64.so.1 alias to SYMLINKS.txt"
    printf '%s\n' "$ALIAS_LINE" >> "$SYMLINKS_TXT"
fi

# Re-zip. -X strips extra fields (uid/gid that bionic doesn't care
# about); -y preserves symlinks as zip-symlink entries. We mostly
# don't have inline symlinks (SYMLINKS.txt handles them), but -y is
# defensive.
echo "build: zipping → $OUT_ZIP"
rm -f "$OUT_ZIP"
( cd "$ROOTFS" && zip -qry "$OUT_ZIP.tmp" . )
mv "$OUT_ZIP.tmp" "$OUT_ZIP"

SIZE_MB=$(( $(stat -f%z "$OUT_ZIP" 2>/dev/null || stat -c%s "$OUT_ZIP") / 1024 / 1024 ))
echo "build: done — $OUT_ZIP (${SIZE_MB} MB)"
