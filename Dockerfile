# Reproducible build environment for the AOSP goldfish (emulator) kernel.
# amd64 is required: the AOSP prebuilt Clang toolchain is x86_64-only, so on
# Apple Silicon this image runs under emulation (--platform=linux/amd64).
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates python3 python3-pip \
      build-essential bc bison flex libssl-dev libelf-dev \
      cpio kmod rsync xz-utils zip unzip \
      ccache gnupg openssl libncurses5-dev libncursesw5-dev \
      gawk file lzop lz4 && \
    rm -rf /var/lib/apt/lists/*

# Google's `repo` tool (fetches the kernel manifest).
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo && \
    chmod +x /usr/local/bin/repo

# `repo` needs a git identity to run.
RUN git config --global user.email "build@local" && \
    git config --global user.name "build" && \
    git config --global color.ui false

WORKDIR /src
