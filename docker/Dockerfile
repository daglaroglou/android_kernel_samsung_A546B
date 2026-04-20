# Reproducible environment aligned with .github/workflows/build_kernels.yml
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    git device-tree-compiler lz4 xz-utils zlib1g-dev \
    openjdk-17-jdk-headless gcc g++ python3 python-is-python3 \
    p7zip-full android-sdk-libsparse-utils erofs-utils default-jdk-headless \
    gnupg flex bison gperf build-essential \
    zip curl libc6-dev libncurses-dev libx11-dev libreadline-dev \
    libgl1 libgl1-mesa-dev bc grep tofrodos \
    python3-markdown libxml2-utils xsltproc libtinfo6 make repo cpio kmod openssl \
    libelf-dev pahole libssl-dev libarchive-tools zstd rsync \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    ca-certificates wget gawk \
    && rm -rf /var/lib/apt/lists/*

ENV TOOLCHAIN_DIR=/opt/toolchain/clang-r450784c
ENV TOOLCHAIN_ARCHIVE_URL=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/llvm-r450784/clang-r450784c.tar.gz

RUN mkdir -p "$TOOLCHAIN_DIR" \
    && rm -f /tmp/clang.tar.gz \
    && curl -fL --retry 5 --retry-delay 10 --output /tmp/clang.tar.gz "$TOOLCHAIN_ARCHIVE_URL" \
    && tar -xf /tmp/clang.tar.gz -C "$TOOLCHAIN_DIR" \
    && rm -f /tmp/clang.tar.gz

ENV PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

COPY docker/build-kernel.sh /usr/local/bin/build-kernel.sh
RUN chmod +x /usr/local/bin/build-kernel.sh

WORKDIR /kernel
ENTRYPOINT ["/usr/local/bin/build-kernel.sh"]
