#!/usr/bin/env bash
# Runs INSIDE the Docker container (see ../build.sh).
#
#   /src  -> kernel source tree (a Docker named volume, so it is case-sensitive
#            and the ~2 GB repo checkout persists across runs)
#   /out  -> bind mount for build artifacts (Image, modules)
#
# Re-runnable: repo init/sync is skipped if already present, and the defconfig
# patches are idempotent.
set -euo pipefail

cd /src

BRANCH="${KERNEL_BRANCH:-common-android11-5.4-lts}"
BUILD_CONFIG_PATH="common-modules/virtual-device/build.config.goldfish.aarch64"

# --- 1. Fetch the kernel source -------------------------------------------
if [ ! -d .repo ]; then
  echo "=== repo init ($BRANCH) ==="
  repo init --depth=1 -u https://android.googlesource.com/kernel/manifest -b "$BRANCH"
fi

echo "=== repo sync (first run: 10-30 min) ==="
repo sync -c -j8 --no-clone-bundle --no-tags --optimized-fetch --prune 2>&1 | tail -5
echo "=== sync done, tree size: $(du -sh /src | cut -f1) ==="

# --- 2. Patch the goldfish defconfig fragment -----------------------------
FRAGMENT="common-modules/virtual-device/goldfish_defconfig.fragment"
[ -f "$FRAGMENT" ] || { echo "ERROR: $FRAGMENT missing (sync interrupted?)"; exit 1; }

# Idempotent: strip any prior block we added, then re-append the canonical one.
sed -i '/# --- afl-android-emulator-kernel begin ---/,/# --- afl-android-emulator-kernel end ---/d' "$FRAGMENT"
cat >> "$FRAGMENT" <<'EOF'

# --- afl-android-emulator-kernel begin ---
# System V IPC: AFL++'s default shmget-based coverage bitmap needs this.
# Stock goldfish kernels ship CONFIG_SYSVIPC=n, which breaks the forkserver.
CONFIG_SYSVIPC=y
CONFIG_SYSVIPC_SYSCTL=y
CONFIG_POSIX_MQUEUE=y
# Host glibc multiarch include paths don't resolve under AOSP Clang -> disable.
# CONFIG_UAPI_HEADER_TEST is not set
# Build virtio drivers in-kernel so first-stage init doesn't depend on module
# load order (some become built-in below to avoid ramdisk module churn).
CONFIG_VIRTIO=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_PCI_LEGACY=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_PMEM=y
# virtio-rng probe is broken in 5.4.302 on this QEMU virt board and leaves
# /dev/hw_random half-initialized, hanging init's MixHwrngIntoLinuxRng. With
# HW_RANDOM=n the node is never created and init treats ENOENT as a no-op.
# CONFIG_HW_RANDOM is not set
# CONFIG_HW_RANDOM_VIRTIO is not set
# CONFIG_HW_RANDOM_HISI is not set
# --- afl-android-emulator-kernel end ---
EOF
echo "=== fragment tail ==="; tail -12 "$FRAGMENT"

# --- 3. Relax goldfish_drivers build-time #error guards -------------------
# defconfig_test.h has `#ifdef CONFIG_X / #error "X is a module" / #endif`
# guards that fail the build for configs we just promoted to =y. Strip them.
TEST_H="common-modules/virtual-device/goldfish_drivers/defconfig_test.h"
if [ -f "$TEST_H" ]; then
  for sym in HW_RANDOM_VIRTIO VIRTIO_BLK VIRTIO_CONSOLE VIRTIO_INPUT \
             VIRTIO_MMIO VIRTIO_NET VIRTIO_PCI VIRTIO_PMEM; do
    sed -i "/^#ifdef CONFIG_${sym}$/,/^#endif$/d" "$TEST_H"
  done
  echo "=== defconfig_test.h stripped ==="
fi

# --- 4. Build --------------------------------------------------------------
export BUILD_CONFIG="$BUILD_CONFIG_PATH"
export OUT_DIR="out/android11-5.4-goldfish-aarch64"
echo "=== building (slow part) ==="
time bash build/build.sh

DIST=$(find out -type d -name dist -path '*goldfish-aarch64*' | head -1)
echo "=== dist: $DIST ==="; ls -la "$DIST"

# --- 5. Collect artifacts into /out ---------------------------------------
[ -f "$DIST/Image" ] || { echo "ERROR: no Image in $DIST"; exit 1; }
cp "$DIST/Image" /out/Image-sysvipc
echo "=== Image -> /out/Image-sysvipc ($(stat -c%s /out/Image-sysvipc) bytes) ==="

# Freshly-built modules, needed by repack-ramdisk.sh
rm -rf /out/modules && mkdir -p /out/modules
find "$DIST" -name '*.ko' -exec cp {} /out/modules/ \;
echo "=== copied $(ls /out/modules/*.ko 2>/dev/null | wc -l | tr -d ' ') modules -> /out/modules ==="
