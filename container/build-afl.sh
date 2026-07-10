#!/usr/bin/env bash
# Runs INSIDE the Docker container (see ../build-afl.sh).
#
# Cross-builds the on-device AFL++ binaries for Android arm64 and stages them
# into /out in the exact layout the fuzzing-engine expects under
# $FUZZING_AFL_ARM64 (afl-fuzz at top, afl-frida-trace.so under lib/arm64-v8a/,
# libdislocator.so + include/ at top).
#
# Built UNPATCHED on purpose: the custom SysVIPC kernel from this repo removes
# the reason for the memfd patch, and building against upstream's own pinned
# frida-gum devkit removes the Frida 16-vs-17 API clash. (Targets a stock/
# Android-12+ device? Apply the memfd patch separately — out of scope here.)
#
# NDK is NOT pinned. It is resolved from the environment:
#   * a Linux NDK mounted at /ndk (has toolchains/llvm/prebuilt/linux-x86_64)
#     is used directly;
#   * otherwise the same version ($NDK_VERSION) is fetched via sdkmanager.
#
# Mounts (set by ../build-afl.sh):
#   /out   -> bind mount == $FUZZING_AFL_ARM64 on the host  (final staging)
#   /ndk   -> host $FUZZING_NDK, read-only (used only if it is a Linux NDK)
#   /afl   -> named volume: persistent AFLplusplus checkout + cached devkit
set -euo pipefail

: "${NDK_VERSION:?NDK_VERSION not set (host launcher derives it from \$FUZZING_NDK)}"
AFL_REF="${AFL_REF:-}"          # optional AFLplusplus commit/tag for reproducibility
STAGE=/out

# Cross-compiling to arm64: skip AFL's host x86 codegen self-check (make reads this).
export AFL_NO_X86=1

echo "== 1. resolve a Linux NDK (unpinned; requested=$NDK_VERSION) =="
if [ -x "/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  NDK=/ndk
  echo "  using the Linux NDK mounted at /ndk"
else
  # Host NDK is macOS-only (its clang can't run in this Linux container). Fetch a
  # Linux NDK via sdkmanager. --channel=3 (canary) so beta/preview versions like
  # the env one resolve. If the exact version isn't downloadable, fall back to the
  # newest offered NDK so the build stays seamless.
  echo "  mounted NDK is not Linux-usable — fetching a Linux NDK via sdkmanager"
  SM="sdkmanager --sdk_root=$ANDROID_SDK_ROOT --channel=3"
  # Accept licenses once up front (guarded — `yes|` gets SIGPIPE, which pipefail
  # would otherwise treat as fatal). Installs below then run without a `yes` pipe.
  yes | $SM --licenses >/dev/null 2>&1 || true
  if $SM "ndk;$NDK_VERSION" >/dev/null 2>&1; then
    echo "  installed ndk;$NDK_VERSION"
  else
    # Exact (often preview/beta) version not downloadable — pick the newest STABLE
    # NDK so the build stays seamless and reproducible.
    ALT=$(sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --list 2>/dev/null \
            | sed -n 's/^ *\(ndk;[0-9][^ ]*\).*/\1/p' | sort -V | tail -1)
    [ -n "$ALT" ] || { echo "ERROR: no installable NDK found via sdkmanager" >&2; exit 1; }
    echo "  ndk;$NDK_VERSION not downloadable — falling back to newest stable: $ALT"
    sdkmanager --sdk_root="$ANDROID_SDK_ROOT" "$ALT" >/dev/null
    NDK_VERSION="${ALT#ndk;}"
  fi
  NDK="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
fi
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
# Pick the LOWEST API >= 26 clang wrapper. AFL's build feature-tests shmget and
# only falls back to the (bionic-missing) shm_open/USEMMAP path if it fails;
# shmget/shmat/shmctl are __INTRODUCED_IN(26), so anything below 26 wrongly
# triggers USEMMAP and fails to compile. API 26 also keeps binaries runnable on
# any API-26+ device (ours is 30).
TARGET_CC=""
for api in 26 27 28 29 30 31 32 33; do
  c="$TC/aarch64-linux-android${api}-clang"
  [ -x "$c" ] && { TARGET_CC="$c"; break; }
done
[ -n "$TARGET_CC" ] || {
  echo "ERROR: no aarch64-linux-android{26..33}-clang under $TC" >&2; exit 1; }
export TARGET_CC TARGET_CXX="${TARGET_CC}++"
echo "  using $(basename "$TARGET_CC")"
"$TARGET_CC" --version | head -1

echo "== 2. AFLplusplus checkout (persistent /afl volume) =="
if [ ! -d /afl/.git ]; then
  git clone https://github.com/AFLplusplus/AFLplusplus /afl
fi
cd /afl
if [ -n "$AFL_REF" ]; then
  git fetch -q origin || true
  git checkout -q "$AFL_REF"
  make -C frida_mode clean >/dev/null 2>&1 || true   # ref changed: drop stale objects
fi
DEVKIT_VER=$(sed -n 's/^GUM_DEVKIT_VERSION *= *//p' frida_mode/GNUmakefile | tr -d ' ')
echo "  AFL $(git rev-parse --short HEAD)  frida-gum devkit $DEVKIT_VER (android-arm64)"

# AFL cross-compiles as if the target were Linux (uname says Linux), so its
# Linux default appends `-lrt` via `override LDFLAGS +=` (which command-line
# LDFLAGS cannot remove). bionic has no librt — those symbols are in libc — so
# the -lrt link makes AFL's shmget probe fail and wrongly fall back to the
# USEMMAP/shm_open path bionic also lacks. Drop -lrt from that one line so the
# probe passes and afl-fuzz builds on the native SysV shmem path (which works
# with this repo's SysVIPC kernel at run time). Idempotent.
sed -i 's/override LDFLAGS += -ldl -lrt -lm/override LDFLAGS += -ldl -lm/' /afl/GNUmakefile

echo "== 3. build afl-fuzz (Android arm64, native SysV shmem) =="
make -C /afl afl-fuzz CC="$TARGET_CC" CXX="$TARGET_CXX"
file /afl/afl-fuzz

echo "== 4. build frida-mode afl-frida-trace.so (unpatched, android-arm64) =="
# CC/CXX/TARGET_* -> NDK clang (target objects + final .so link);
# HOST_CC/HOST_CXX -> gcc/g++ so the build-time tool (bin2c) stays host-runnable.
# The frida-gum android-arm64 devkit is downloaded (and cached in /afl) by make.
make -C /afl/frida_mode \
    CC="$TARGET_CC" CXX="$TARGET_CXX" \
    TARGET_CC="$TARGET_CC" TARGET_CXX="$TARGET_CXX" \
    HOST_CC=cc HOST_CXX=c++ \
    ARCH=arm64
# The makefile stages the .so at the AFL root (/afl); build/ also has a copy.
FRIDA_SO="$(ls /afl/afl-frida-trace.so /afl/frida_mode/build/afl-frida-trace.so 2>/dev/null | head -1)"
[ -n "$FRIDA_SO" ] && [ -f "$FRIDA_SO" ] || { echo "ERROR: afl-frida-trace.so was not built" >&2; exit 1; }
file "$FRIDA_SO"

echo "== 5. build libdislocator.so (guard-page allocator for heap-write detection) =="
"$TARGET_CC" -O2 -fPIC -shared -I/afl/include \
    -o /afl/libdislocator.so /afl/utils/libdislocator/libdislocator.so.c
file /afl/libdislocator.so

echo "== 6. best-effort afl-tmin / afl-cmin (arm64; optional) =="
make -C /afl afl-tmin afl-cmin CC="$TARGET_CC" CXX="$TARGET_CXX" \
    || echo "  (tmin/cmin skipped — optional, minimize still works without them)"

echo "== 7. stage into /out (== \$FUZZING_AFL_ARM64) =="
# Clear stale entries (e.g. a leftover include symlink) so mkdir/cp are clean.
rm -rf "$STAGE/include" "$STAGE/lib/arm64-v8a"
mkdir -p "$STAGE/lib/arm64-v8a" "$STAGE/include"
cp -f /afl/afl-fuzz          "$STAGE/"
cp -f "$FRIDA_SO"            "$STAGE/lib/arm64-v8a/afl-frida-trace.so"
cp -f /afl/libdislocator.so  "$STAGE/"
for t in afl-tmin afl-cmin; do [ -x "/afl/$t" ] && cp -f "/afl/$t" "$STAGE/"; done
cp -a /afl/include/. "$STAGE/include/"

echo "== staged files =="
( cd "$STAGE" && find . -maxdepth 2 -type f | sort | sed 's/^/  /' )
echo "DONE_BUILD_AFL"
