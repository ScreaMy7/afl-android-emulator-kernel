# Prebuilt binaries

These artifacts are distributed as **GitHub Release assets**, not committed to
the git tree (they're binaries and would bloat the repo). `.gitignore` excludes
them here.

Expected files (drop them in this directory, or point `boot.sh` at them via
`KERNEL=` / `RAMDISK=`):

| File | Size | What |
|---|---|---|
| `Image-sysvipc` | ~26 MB | Custom goldfish kernel with `CONFIG_SYSVIPC=y` |
| `ramdisk-sysvipc.img` | ~7 MB | Ramdisk repacked with matching modules |

## Publishing a release

After a build, upload the artifacts from `./out/` to a GitHub Release, e.g. with
the GitHub CLI:

```bash
gh release create v1.0 \
  out/Image-sysvipc \
  out/ramdisk-sysvipc.img \
  --title "android11-5.4 goldfish arm64 (SysV IPC)" \
  --notes "AFL++-ready kernel. See README for the config delta."
```

## Provenance

Built from `common-android11-5.4-lts` via [`../build.sh`](../build.sh). The exact
config delta is in [`../config/goldfish_defconfig.fragment`](../config/goldfish_defconfig.fragment).
Kernel string reported by the reference build:
`5.4.302-android11-2-g73e89fa56fdb`.
