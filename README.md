# afl-android-emulator-kernel

A reproducible, AFL++-ready kernel for the Android emulator (goldfish/`ranchu`).

The stock Android emulator kernel ships with `CONFIG_SYSVIPC=n`. AFL++'s default
coverage bitmap uses SysV shared memory (`shmget`), so on a stock emulator the
forkserver handshake fails and you can't fuzz. This repo rebuilds the AOSP
goldfish kernel (`common-android11-5.4-lts`) with `CONFIG_SYSVIPC=y` and a few
supporting flags, so you can boot an ordinary AVD into a fuzzing-capable emulator
with a single `-kernel` swap — **no changes to the AVD or system image**.

> The AVD stays stock. Only the kernel + ramdisk are swapped at boot time via
> the emulator's `-kernel` / `-ramdisk` flags.

## What you get

- A [`Dockerfile`](Dockerfile) pinning the AOSP kernel toolchain (Ubuntu 22.04,
  `repo`, Clang deps) — amd64, runs under emulation on Apple Silicon.
- [`build.sh`](build.sh) — one command to sync the kernel source, apply the
  config delta, build, and (optionally) repack the ramdisk with matching modules.
- [`boot.sh`](boot.sh) — boot any existing AVD with the custom kernel.
- The exact config delta, documented in
  [`config/goldfish_defconfig.fragment`](config/goldfish_defconfig.fragment).
- The non-obvious build gotchas in [`docs/GOTCHAS.md`](docs/GOTCHAS.md).

Prebuilt binaries (`Image-sysvipc`, `ramdisk-sysvipc.img`) are published as
**GitHub Release assets**, not committed to the tree — see
[`prebuilt/README.md`](prebuilt/README.md).

## Quick start (prebuilt)

1. Download `Image-sysvipc` and `ramdisk-sysvipc.img` from the latest
   [Release](../../releases) into `prebuilt/`.
2. Have a stock API-30 arm64 AVD (e.g. AOSP ATD). Create one if needed:
   ```bash
   sdkmanager "system-images;android-30;aosp_atd;arm64-v8a"
   avdmanager create avd -n fuzz30 -k "system-images;android-30;aosp_atd;arm64-v8a"
   ```
3. Boot it with the custom kernel:
   ```bash
   AVD_NAME=fuzz30 ./boot.sh
   ```
4. Verify SysV IPC is live (see below).

## Build from source

Requires Docker. On Apple Silicon, Docker Desktop runs the amd64 image under
emulation automatically.

```bash
# Kernel Image + modules -> ./out
./build.sh

# Also repack the ramdisk so its modules match the new kernel:
ORIG_RAMDISK="$ANDROID_SDK_ROOT/system-images/android-30/aosp_atd/arm64-v8a/ramdisk.img" \
  ./build.sh
```

Outputs land in `./out/`:
- `Image-sysvipc` — the kernel
- `modules/` — freshly-built `.ko` files
- `ramdisk-sysvipc.img` — repacked ramdisk (only if `ORIG_RAMDISK` was set)

First run does a full `repo sync` (10–30 min) into a persistent Docker volume;
subsequent builds reuse it.

## Verify

After `boot.sh`, confirm the kernel is the custom one and SysV IPC works:

```bash
adb wait-for-device
# SysV IPC procfs entries exist only when CONFIG_SYSVIPC=y:
adb shell 'ls -la /proc/sysvipc/'          # -> msg  sem  shm
adb shell 'ipcs -m'                         # runs without error
# Confirm the config directly (if /proc/config.gz is present):
adb shell 'zcat /proc/config.gz' | grep -E 'CONFIG_SYSVIPC|CONFIG_HW_RANDOM'
```

A working AFL++ forkserver on this kernel is the real acceptance test: point an
arm64 AFL++ frida-mode build at any target and confirm the handshake completes.

## Config delta

The complete set of flags flipped vs. stock is in
[`config/goldfish_defconfig.fragment`](config/goldfish_defconfig.fragment).
Summary:

| Flag | Why |
|---|---|
| `CONFIG_SYSVIPC=y` (+ `SYSVIPC_SYSCTL`, `POSIX_MQUEUE`) | AFL++ `shmget` coverage bitmap / forkserver |
| `# CONFIG_UAPI_HEADER_TEST is not set` | UAPI header self-test fails under AOSP Clang |
| `CONFIG_VIRTIO_* = y` | virtio drivers built-in, independent of module load order |
| `# CONFIG_HW_RANDOM is not set` | broken virtio-rng probe hangs boot on 5.4.302 |

## AFL++ binaries (the other native-track prerequisite)

The custom kernel is one half of what on-device fuzzing needs; the other is the
AFL++ binaries built **for the device** (`afl-fuzz`, `afl-frida-trace.so`,
`libdislocator.so`, Android arm64). Those can't be built on a macOS host —
AFL++ frida-mode's makefile hardcodes an Apple target there — so `build-afl.sh`
cross-builds them in the same Linux-container approach used for the kernel.

```sh
export FUZZING_NDK=/path/to/Android/sdk/ndk/<version>   # taken from env, not pinned
./build-afl.sh
```

It builds the AFL image (`Dockerfile.afl`), then in the container clones
AFLplusplus, resolves an NDK (the mounted one if it's a Linux NDK, else it
fetches the same version), and builds **unpatched** — the SysVIPC kernel above
removes the need for the memfd patch, and building against upstream's own frida
devkit avoids the Frida 16-vs-17 API clash. Binaries are staged straight into
`$FUZZING_AFL_ARM64` (default `~/.local/share/aflpp-arm64`) in the layout the
fuzzing-engine expects, so `source env.sh` in that repo picks them up and Gate 0
`patched_afl` passes with no extra config.

> Reproducibility: pin an AFLplusplus commit with `AFL_REF=<sha>`. Targeting a
> stock (non-SysVIPC) or Android-12+ device instead? Those still need the memfd /
> ashmem patch — apply it separately; the default build here is for this repo's
> API-30 SysVIPC AVD.

## Layout

```
Dockerfile                              kernel toolchain image
Dockerfile.afl                          AFL cross-build image (NDK unpinned, from env)
build.sh                                host: build the SysVIPC kernel
build-afl.sh                            host: cross-build on-device AFL++ -> $FUZZING_AFL_ARM64
boot.sh                                 host: boot an AVD with the custom kernel
container/sync-and-build.sh             in-container: sync + patch + build kernel
container/build-afl.sh                  in-container: cross-build afl-fuzz + afl-frida-trace.so
container/repack-ramdisk.sh             in-container: rebuild ramdisk w/ modules
config/goldfish_defconfig.fragment      the documented config delta
docs/GOTCHAS.md                         non-obvious build pitfalls
prebuilt/                               Release binaries land here (gitignored)
```

## Scope / notes

- Targets `common-android11-5.4-lts` (API 30). Other API levels use different
  kernel branches; override with `KERNEL_BRANCH=...`, though the driver/config
  patches may need adjusting.
- Intended for **security research and fuzzing on hardware you own**. The kernel
  changes only enable instrumentation infrastructure (SysV IPC); they don't
  weaken any security boundary of a target app.

## License

See [`LICENSE`](LICENSE). Set the copyright holder before publishing.
