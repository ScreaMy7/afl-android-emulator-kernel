#!/usr/bin/env bash
# Boot a STOCK AVD using the custom AFL++-ready kernel + ramdisk.
# The AVD itself is unmodified — only the kernel/ramdisk are swapped at boot.
#
# Usage:
#   AVD_NAME=fuzz30 ./boot.sh
#
# Env overrides:
#   AVD_NAME   name of an existing AVD (required)  — see `emulator -list-avds`
#   KERNEL     kernel Image   (default ./prebuilt/Image-sysvipc)
#   RAMDISK    ramdisk image  (default ./prebuilt/ramdisk-sysvipc.img)
#   PORT       emulator port  (default 5554)
# Extra emulator args pass through: ./boot.sh -show-kernel
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AVD="${AVD_NAME:?set AVD_NAME to an existing AVD, e.g. AVD_NAME=fuzz30}"
KERNEL="${KERNEL:-$ROOT/prebuilt/Image-sysvipc}"
RAMDISK="${RAMDISK:-$ROOT/prebuilt/ramdisk-sysvipc.img}"
PORT="${PORT:-5554}"

command -v emulator >/dev/null || { echo "ERROR: 'emulator' not on PATH (source your Android SDK env)"; exit 1; }
[ -f "$KERNEL" ]  || { echo "ERROR: kernel not found: $KERNEL"; exit 1; }
[ -f "$RAMDISK" ] || { echo "ERROR: ramdisk not found: $RAMDISK"; exit 1; }

exec emulator -avd "$AVD" \
  -kernel "$KERNEL" \
  -ramdisk "$RAMDISK" \
  -no-window -no-audio -no-boot-anim -no-snapshot -writable-system \
  -gpu swiftshader_indirect \
  -port "$PORT" \
  "$@"
