#!/usr/bin/env bash
# Host-side orchestrator. Builds the toolchain image, syncs + builds the kernel
# in a container, and (optionally) repacks the ramdisk with matching modules.
#
# Usage:
#   ./build.sh                       # build Image (+ modules) into ./out
#   ORIG_RAMDISK=/path/ramdisk.img ./build.sh   # also repack the ramdisk
#
# Env overrides:
#   KERNEL_BRANCH   AOSP kernel branch      (default common-android11-5.4-lts)
#   OUT_DIR         host output dir         (default ./out)
#   ORIG_RAMDISK    original ramdisk.img to repack modules into (optional)
#                   e.g. $ANDROID_SDK_ROOT/system-images/android-30/<variant>/<abi>/ramdisk.img
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="afl-android-kbuild"
OUT="${OUT_DIR:-$ROOT/out}"
SRC_VOL="afl-kbuild-src"          # named volume => case-sensitive, persistent
mkdir -p "$OUT"

command -v docker >/dev/null || { echo "ERROR: docker not found on PATH"; exit 1; }

# A Docker *named volume* (not a macOS bind mount) is required for the source:
# APFS is case-insensitive and the AOSP tree has case-colliding paths.
docker volume create "$SRC_VOL" >/dev/null

echo "=== [1/3] building toolchain image ($IMAGE) ==="
docker build --platform=linux/amd64 -t "$IMAGE" "$ROOT"

echo "=== [2/3] sync + build kernel ==="
docker run --rm --platform=linux/amd64 \
  -e KERNEL_BRANCH="${KERNEL_BRANCH:-common-android11-5.4-lts}" \
  -v "$SRC_VOL:/src" \
  -v "$OUT:/out" \
  -v "$ROOT/container:/scripts:ro" \
  "$IMAGE" bash /scripts/sync-and-build.sh

if [ -n "${ORIG_RAMDISK:-}" ]; then
  echo "=== [3/3] repack ramdisk from $ORIG_RAMDISK ==="
  cp "$ORIG_RAMDISK" "$OUT/ramdisk-orig.img"
  docker run --rm --platform=linux/amd64 \
    -v "$OUT:/out" \
    -v "$ROOT/container:/scripts:ro" \
    "$IMAGE" bash /scripts/repack-ramdisk.sh
else
  echo "=== [3/3] skipped ramdisk repack (set ORIG_RAMDISK to enable) ==="
fi

echo
echo "Done. Artifacts in $OUT:"
ls -la "$OUT" 2>/dev/null || true
echo
echo "Next: boot a stock AVD with the custom kernel — see ./boot.sh and README.md"
