# Gotchas

Hard-won notes from building this kernel. Each of these cost real time.

## 1. macOS is case-insensitive — the source tree needs a case-sensitive FS

The AOSP kernel tree contains paths that collide under a case-insensitive
filesystem (APFS default). A macOS **bind mount** into the container will
corrupt the checkout. `build.sh` therefore syncs into a Docker **named volume**
(`afl-kbuild-src`), which lives on the Linux VM's ext4 and is case-sensitive.
Only the small `out/` artifacts are bind-mounted back to the host.

## 2. The toolchain is x86_64-only

AOSP's prebuilt Clang is x86_64. On Apple Silicon the build image must run as
`--platform=linux/amd64` (emulated). It works, just slower than native.

## 3. `CONFIG_UAPI_HEADER_TEST` breaks the build

Host glibc multiarch include paths don't resolve under AOSP Clang, so the UAPI
header self-test fails. Disable it (`# CONFIG_UAPI_HEADER_TEST is not set`).

## 4. `defconfig_test.h` #error guards

`common-modules/virtual-device/goldfish_drivers/defconfig_test.h` has blocks
like:

```c
#ifdef CONFIG_VIRTIO_BLK
#error "VIRTIO_BLK is a module"
#endif
```

for drivers it expects to be modules. Once we promote those to `=y` the guards
fail the build. `sync-and-build.sh` strips the matching `#ifdef … #endif` blocks.

## 5. `CONFIG_HW_RANDOM` hangs boot

The virtio-rng probe is broken in 5.4.302 on this QEMU virt board. It leaves
`/dev/hw_random` half-initialized, and init hangs in `MixHwrngIntoLinuxRng`
waiting on it. Setting `CONFIG_HW_RANDOM=n` means the node is never created and
init treats the `ENOENT` as a no-op. Boot proceeds normally.

## 6. `ramdisk.img` is TWO concatenated CPIO archives

The stock goldfish ramdisk is `part1 (first-stage init)` + `part2 (modules)`,
concatenated. `cpio -t` reads only the first archive, so a naive extract/repack
**silently drops every kernel module** and the rebuilt kernel then can't load
its modules. `repack-ramdisk.sh` splits on the first `TRAILER!!!` + zero padding,
rebuilds part2 with the new modules, and re-concatenates. Several public guides
get this wrong.

## 7. Module version mismatch

Modules built against the new kernel must exactly match its `vermagic`. Any
`.ko` in the original ramdisk without a freshly-built counterpart is removed
from both the filesystem and `modules.load`, otherwise init fails the version
check at load time.
