# dpkg path-rewrite patches

**Status:** Active

Two patches in crates/gpui_android/termux-patches/dpkg/: lib-dpkg-tarfn.c.patch rewrites /data/data/com.termux/* paths in dpkg's tar_extractor; src-deb-extract.c.patch does the same in dpkg-deb. Lets pkg install <upstream-deb> land files at our prefix instead of com.termux. Layer 1 of the three-layer L2g patch stack.

**Detailed writeup: TODO.** Stub created so the index links resolve.
