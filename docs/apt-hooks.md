# Apt Post-Invoke + Pre-Install hooks

**Status:** Active

Several DPkg hooks in $PREFIX/etc/apt/apt.conf.d/: 99-zed-rewrite-postinst (sed maintainer scripts), 98-zed-patchelf (set RPATH on freshly-installed ELFs), 97-zed-node-platform (re-apply node platform patch after pkg install nodejs), pre-install hook for shebang fixups. Each hook is idempotent.

**Detailed writeup: TODO.** Stub created so the index links resolve.
