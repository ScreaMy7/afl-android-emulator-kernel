#!/usr/bin/env bash
# Host-side launcher — cross-builds the on-device AFL++ binaries in a Linux
# container and stages them into $FUZZING_AFL_ARM64 so the fuzzing-engine picks
# them up with zero extra config (Gate 0 `patched_afl` goes green).
#
# This is the companion to build.sh: build.sh produces the SysVIPC *kernel*;
# build-afl.sh produces the matching on-device AFL *binaries*. Together this repo
# provides both native-track prerequisites, version-matched.
#
# The NDK is taken from the environment, never pinned. Output goes to the env
# default so it "just works".
#
# Usage:
#   FUZZING_NDK=/path/to/ndk ./build-afl.sh
#
# Env overrides:
#   FUZZING_NDK        installed Android NDK (required; also ANDROID_NDK_HOME/ROOT)
#   FUZZING_AFL_ARM64  staging dir            (default ~/.local/share/aflpp-arm64)
#   AFL_REF            AFLplusplus commit/tag to pin for reproducibility (optional)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="afl-android-userland"
AFL_VOL="afl-userland-src"        # named volume => case-sensitive, persistent, caches the devkit
NDK_VOL="afl-sdk-ndk-cache"       # caches an sdkmanager-fetched NDK across runs
STAGE="${FUZZING_AFL_ARM64:-$HOME/.local/share/aflpp-arm64}"

NDK="${FUZZING_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
[ -n "$NDK" ] && [ -d "$NDK" ] || {
  echo "ERROR: set FUZZING_NDK to an installed Android NDK (got: '${NDK:-unset}')" >&2; exit 1; }

# Derive the (unpinned) NDK version from the NDK itself, so the container fetches
# the matching Linux NDK when the host one is macOS-only.
NDK_VERSION="$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" 2>/dev/null | tr -d ' ')"
[ -n "$NDK_VERSION" ] || {
  echo "ERROR: cannot read Pkg.Revision from $NDK/source.properties" >&2; exit 1; }

command -v docker >/dev/null || { echo "ERROR: docker not found on PATH" >&2; exit 1; }
mkdir -p "$STAGE"
docker volume create "$AFL_VOL" >/dev/null
docker volume create "$NDK_VOL" >/dev/null

echo "=== [1/2] building AFL cross-build image ($IMAGE) ==="
docker build --platform=linux/amd64 -f "$ROOT/Dockerfile.afl" -t "$IMAGE" "$ROOT"

echo "=== [2/2] cross-build AFL++ (NDK $NDK_VERSION) -> $STAGE ==="
# The build script is baked into the image (COPY) — Colima doesn't mount
# external volumes like /Volumes/*, so a bind mount of it would be empty.
# /out and /ndk live under $HOME, which Colima does mount.
docker run --rm --platform=linux/amd64 \
  -e NDK_VERSION="$NDK_VERSION" \
  -e AFL_REF="${AFL_REF:-}" \
  -v "$AFL_VOL:/afl" \
  -v "$NDK_VOL:/opt/android-sdk/ndk" \
  -v "$STAGE:/out" \
  -v "$NDK:/ndk:ro" \
  "$IMAGE" bash /opt/build-afl.sh

echo
echo "Done. Staged AFL++ in $STAGE:"
ls -la "$STAGE" 2>/dev/null || true
echo
echo "The fuzzing-engine finds these automatically via FUZZING_AFL_ARM64."
echo "Verify:  cd <fuzzing-engine> && source env.sh && \\"
echo "         python3 orchestrator/Tools/verifier.py native --apk samples/FuzzLab.apk"
