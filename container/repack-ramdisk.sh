#!/usr/bin/env bash
# Runs INSIDE the Docker container (needs Linux cpio).
#
# Rebuilds ramdisk.img so its kernel modules match the kernel we just built.
# The stock goldfish ramdisk.img is TWO concatenated CPIO archives:
#   part1 = first-stage init, part2 = /lib/modules/*.ko
# `cpio -t` only reads the first archive, so a naive extract/repack silently
# drops every module. We split on the first TRAILER!!! + padding, rebuild
# part2 with our modules, and re-concatenate.
#
#   /out/ramdisk-orig.img   input: original ramdisk from the AVD system image
#   /out/modules/*.ko       input: modules from sync-and-build.sh
#   /out/ramdisk-sysvipc.img output
set -euo pipefail

ORIG="${ORIG_RAMDISK:-/out/ramdisk-orig.img}"
MODULES="${MODULES_DIR:-/out/modules}"
OUTIMG="${OUT_RAMDISK:-/out/ramdisk-sysvipc.img}"

[ -f "$ORIG" ]     || { echo "ERROR: original ramdisk not found at $ORIG"; exit 1; }
[ -d "$MODULES" ]  || { echo "ERROR: modules dir not found at $MODULES (run sync-and-build.sh first)"; exit 1; }

WORK=/tmp/ramdisk-build
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

# 1. Decompress -> raw concatenated cpio (ramdisk may be gzip or raw cpio)
if gzip -t "$ORIG" 2>/dev/null; then
  gunzip -c "$ORIG" > ramdisk.cpio
else
  cp "$ORIG" ramdisk.cpio
fi

# 2. Split into part1 (init) and part2 (modules) at end of first archive
SPLIT=$(python3 -c '
data=open("ramdisk.cpio","rb").read()
i=data.find(b"TRAILER!!!")
e=i+len(b"TRAILER!!!")
while e<len(data) and data[e]==0: e+=1
print(e)')
echo "split at offset $SPLIT"
dd if=ramdisk.cpio of=part1.cpio bs=1 count="$SPLIT" 2>/dev/null
dd if=ramdisk.cpio of=part2.cpio bs=1 skip="$SPLIT" 2>/dev/null

# 3. Extract part2 (the modules archive)
rm -rf part2-fs; mkdir part2-fs
(cd part2-fs && cpio -idm < ../part2.cpio 2>&1 | tail -3)

# 4. Swap in our freshly-built modules; drop any without a rebuilt match
echo "=== replacing modules ==="
replaced=0; missing=0
for ko in "$MODULES"/*.ko; do
  name=$(basename "$ko")
  if [ -f "part2-fs/lib/modules/$name" ]; then
    cp "$ko" "part2-fs/lib/modules/$name"; replaced=$((replaced+1))
  fi
done
for orig in part2-fs/lib/modules/*.ko; do
  name=$(basename "$orig")
  if [ ! -f "$MODULES/$name" ]; then
    echo "INFO: no rebuilt $name -- removing (would fail version check)"
    rm -f "$orig"
    sed -i "/^$name\$/d" part2-fs/lib/modules/modules.load 2>/dev/null || true
    missing=$((missing+1))
  fi
done
echo "replaced: $replaced, removed: $missing"

# 5. Re-cpio part2 (newc = SVR4 no-CRC, matching the original) and reassemble
(cd part2-fs && find . | LC_ALL=C sort | cpio -o -H newc 2>/dev/null > ../part2-new.cpio)
cat part1.cpio part2-new.cpio > ramdisk-new.cpio
gzip -c ramdisk-new.cpio > "$OUTIMG"
echo "=== new ramdisk -> $OUTIMG ($(stat -c%s "$OUTIMG") bytes) ==="
