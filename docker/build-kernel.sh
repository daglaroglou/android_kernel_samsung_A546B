#!/usr/bin/env bash
# Mirrors the `build` job in .github/workflows/build_kernels.yml (patch → make → AnyKernel3 zip).
set -euo pipefail

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Working tree: patches and `out/` live here. When SYNC_SOURCE_DIR is set, it is rsync'd from
# the read-only host mount so your real checkout on the host is never modified.
SYNC_SOURCE_DIR="${SYNC_SOURCE_DIR:-}"
KERNEL_DIR="${KERNEL_DIR:-/kernel}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
PATCHES_DIR="${PATCHES_DIR:-$HOME/kernel_patches}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-/opt/toolchain/clang-r450784c}"

# Bind-mounted repo is owned by host UID; container runs as root — KernelSU setup uses git here.
git config --global --add safe.directory '*'

BUILD_VARIANT="${BUILD_VARIANT:-KernelSU-Next_SUSFS}"
BUILD_LOCALVERSION="${BUILD_LOCALVERSION:--DΛG-KSUN_SUSFS}"
EXTRA_KSU_FLAGS="${EXTRA_KSU_FLAGS:---enable CONFIG_KSU}"

KERNELSU_NEXT_HASH="${KERNELSU_NEXT_HASH:-551ad80473f60e052917aec08abf5323b6ab2f7c}"
SUSFS_HASH="${SUSFS_HASH:-eaa5d299dd85a4230f936b94dc5dd8303f27130a}"
KERNELSU_NEXT_VERSION="${KERNELSU_NEXT_VERSION:-3.2.0}"
SUSFS_VERSION="${SUSFS_VERSION:-2.1.0}"

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

if [[ ! -x "${TOOLCHAIN_DIR}/bin/clang" ]]; then
  echo "ERROR: Clang not found at ${TOOLCHAIN_DIR}/bin/clang" >&2
  exit 1
fi

if [[ -n "$SYNC_SOURCE_DIR" ]]; then
  echo "📋 Syncing $SYNC_SOURCE_DIR/ → $KERNEL_DIR/ (host tree is not modified)"
  mkdir -p "$KERNEL_DIR"
  rsync -a --delete \
    --exclude=out \
    --exclude=docker-output \
    "$SYNC_SOURCE_DIR"/ "$KERNEL_DIR"/
fi

cd "$KERNEL_DIR"

echo "📁 KERNEL_DIR=$KERNEL_DIR"
echo "📁 OUTPUT_DIR=$OUTPUT_DIR"
echo "🔖 Variant: $BUILD_VARIANT"

echo "⬇️  Cloning AnyKernel3 (branch: a54x)..."
rm -rf "$HOME/AnyKernel3"
git clone --depth=1 --branch a54x https://github.com/daglaroglou/AnyKernel3.git "$HOME/AnyKernel3"

echo "⬇️  Cloning WildKernels kernel patches..."
rm -rf "$PATCHES_DIR"
git clone https://github.com/WildKernels/kernel_patches.git "$PATCHES_DIR"

if truthy "${KERNELSU_NEXT:-true}"; then
  cd "$KERNEL_DIR"
  set +u
  echo "🔧 KernelSU-Next (dev)"
  curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s dev
  set -u
  cd "$KERNEL_DIR/KernelSU-Next"
  git checkout "$KERNELSU_NEXT_HASH"
  cd "$KERNEL_DIR"
  echo "✅ KernelSU-Next driver ready"
fi

if truthy "${DROIDSPACES:-true}"; then
  DS_SRC="$HOME/Droidspaces-OSS"
  GKI_DIR="$DS_SRC/Documentation/resources/kernel-patches/GKI"
  echo "⬇️  Cloning Droidspaces-OSS..."
  rm -rf "$DS_SRC"
  git clone --depth=1 https://github.com/ravindu644/Droidspaces-OSS.git "$DS_SRC"
  if [[ ! -d "$GKI_DIR" ]]; then
    echo "❌ GKI patch directory not found: $GKI_DIR" >&2
    exit 1
  fi
  cd "$KERNEL_DIR"
  mapfile -t patchfiles < <(find "$GKI_DIR" -maxdepth 1 -type f -name '*.patch' -printf '%f\n' | LC_ALL=C sort)
  for base in "${patchfiles[@]}"; do
    f="$GKI_DIR/$base"
    case "$base" in
      01.6.1+_disable_crc_checks_for_lkms.patch)
        echo "⏭️  Skipping $base"
        continue
        ;;
      03.5.10_or_lower_use_android_abi_padding_for_posix_mqueue\ copy.patch)
        echo "⏭️  Skipping $base"
        continue
        ;;
    esac
    echo "📋 Copying $base into kernel tree..."
    cp -v "$f" "$KERNEL_DIR/"
    echo "🩹 Applying $base..."
    patch -p1 < "$KERNEL_DIR/$base" || true
  done
  echo "✅ Droidspaces GKI patches applied"
fi

if truthy "${KERNELSU_NEXT:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️  Applying KSU config flags: $EXTRA_KSU_FLAGS"
  ./scripts/config --file arch/arm64/configs/custom.config $EXTRA_KSU_FLAGS
  echo "✅ KSU config flags applied"
fi

if truthy "${SUSFS:-true}"; then
  cd "$HOME"
  echo "⬇️  Cloning SUSFS sources (gki-android13-5.15)..."
  rm -rf "$HOME/susfs4ksu"
  git clone -b gki-android13-5.15 https://gitlab.com/simonpunk/susfs4ksu.git
  cd "$HOME/susfs4ksu"
  git checkout "$SUSFS_HASH"
  echo "✅ SUSFS sources ready"
fi

if truthy "${SUSFS:-true}"; then
  echo "📋 Copying SUSFS patch files into kernel tree..."
  cp "$HOME/susfs4ksu/kernel_patches/KernelSU/"* "$KERNEL_DIR/KernelSU-Next/"
  cp "$HOME/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch" "$KERNEL_DIR/"
  cp "$HOME/susfs4ksu/kernel_patches/fs/"* "$KERNEL_DIR/fs/"
  cp "$HOME/susfs4ksu/kernel_patches/include/linux/"* "$KERNEL_DIR/include/linux/"
  cp "$PATCHES_DIR/next/susfs_fix_patches/v${SUSFS_VERSION}/"*.patch "$KERNEL_DIR/KernelSU-Next/"
  echo "✅ All patch files copied"
fi

if truthy "${SUSFS:-true}"; then
  cd "$KERNEL_DIR"
  sed -i '/#ifdef CONFIG_SECURITY_DEFEX/,/^#endif/d' fs/open.c
  sed -i '/copy_flags = CL_COPY_UNBINDABLE | CL_EXPIRE;/,/#endif/ {
    /#ifdef CONFIG_KDP_NS/,/#endif/ {
      /#else/,/#endif/!d
      /#else/d
      /#endif/d
    }
  }' fs/namespace.c
  echo "🩹 Applying 50_add_susfs_in_gki-android13-5.15.patch..."
  patch -p1 < 50_add_susfs_in_gki-android13-5.15.patch || true

  cd "$KERNEL_DIR/KernelSU-Next"
  if [[ -f 10_enable_susfs_for_ksu.patch ]]; then
    echo "🩹 Applying 10_enable_susfs_for_ksu.patch..."
    patch -p1 < 10_enable_susfs_for_ksu.patch || true
    rm -f 10_enable_susfs_for_ksu.patch
  fi
  rm -f multi_manager.patch multi_sepolicy_fix.patch
  for p in *.patch; do
    [[ -e "$p" ]] || continue
    echo "🩹 Applying $p..."
    patch -p1 < "$p" || true
    rm -f "$p"
  done
  echo "✅ SUSFS patch chain applied"
fi

if truthy "${ZEROMOUNT:-true}"; then
  ZB="$HOME/Super-Builders"
  ZM_PATCH="$ZB/android13-5.15/WildKSU/patches/60_zeromount-android13-5.15.patch"
  echo "⬇️  Cloning Super-Builders..."
  rm -rf "$ZB"
  git clone --depth=1 https://github.com/jimsterino98/Super-Builders.git "$ZB"
  if [[ ! -f "$ZM_PATCH" ]]; then
    echo "ERROR: Zeromount patch not found: $ZM_PATCH" >&2
    exit 1
  fi
  cd "$KERNEL_DIR"
  echo "🩹 Applying 60_zeromount-android13-5.15.patch..."
  cp "$ZM_PATCH" "./60_zeromount-android13-5.15.patch"
  patch -p1 < "60_zeromount-android13-5.15.patch" || true
  rm -f "60_zeromount-android13-5.15.patch"
  if [[ -f fs/proc/task_mmu.c ]] && ! grep -q 'zeromount_spoof_mmap_metadata' fs/proc/task_mmu.c; then
    echo "🔧 Fixing fs/proc/task_mmu.c (zeromount mmap metadata)..."
    _zm_task_mmu=$(mktemp)
    printf '%s\n' \
      '#ifdef CONFIG_ZEROMOUNT' \
      $'\tzeromount_spoof_mmap_metadata(inode, &dev, &ino);' \
      '#endif' > "$_zm_task_mmu"
    sed -i "/pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;/r $_zm_task_mmu" fs/proc/task_mmu.c
    rm -f "$_zm_task_mmu"
  fi
  if [[ -f fs/stat.c.rej ]]; then
    echo "🔧 Fixing fs/stat.c (zeromount_stat_hook)..."
    if ! grep -q 'zeromount_stat_hook(dfd, filename, stat, request_mask, flags)' fs/stat.c; then
      perl -0pi -e 's@(static int vfs_statx\(.*?\)\s*\{.*?orig_flow:\n#endif\n)@$1\n#ifdef CONFIG_ZEROMOUNT\n\tif (filename) {\n\t\tint zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);\n\t\tif (zm_ret != -ENOENT)\n\t\t\treturn zm_ret;\n\t}\n#endif\n\n@s' fs/stat.c
    fi
    rm -f fs/stat.c.rej
  fi
  if [[ -f fs/Kconfig.rej ]]; then
    echo "🔧 Fixing fs/Kconfig (ZEROMOUNT)..."
    if ! grep -q '^config ZEROMOUNT$' fs/Kconfig; then
      perl -0pi -e 's@(config IO_WQ\n\tbool\n)@\1\nconfig ZEROMOUNT\n\tbool "ZeroMount Path Redirection Subsystem"\n\tdefault y\n\thelp\n\t  ZeroMount allows path redirection and virtual file injection\n\t  without mounting filesystems. Useful for systemless modifications.\n\n@' fs/Kconfig
    fi
    rm -f fs/Kconfig.rej
  fi
  rm -f fs/namei.c.rej fs/readdir.c.rej fs/stat.c.rej fs/proc/task_mmu.c.rej 2>/dev/null || true
  echo "✅ Zeromount patch step finished (android13-5.15)"
fi

if truthy "${BBG:-true}"; then
  cd "$KERNEL_DIR"
  echo "⬇️  Applying BBG..."
  wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
  echo "✅ BBG applied"
fi

if truthy "${BBG:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️  Enabling CONFIG_BASEBAND_GUARD..."
  ./scripts/config --file arch/arm64/configs/custom.config --enable CONFIG_BBG
  echo "✅ BBG config enabled"
fi

if truthy "${SUSFS:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️ Enabling CONFIG_KSU_SUSFS..."
  ./scripts/config --file arch/arm64/configs/custom.config --enable CONFIG_KSU_SUSFS
  echo "✅ SUSFS config enabled"
fi

if truthy "${ZEROMOUNT:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️ Enabling CONFIG_ZEROMOUNT..."
  ./scripts/config --file arch/arm64/configs/custom.config --enable CONFIG_ZEROMOUNT
  echo "✅ Zeromount config enabled (custom.config)"
fi

if truthy "${MOUNTIFY:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️ Enabling Mountify options..."
  ./scripts/config --file arch/arm64/configs/custom.config \
    --enable CONFIG_TMPFS_XATTR \
    --enable CONFIG_TMPFS_POSIX_ACL
  echo "✅ Mountify options configured"
fi

if truthy "${DROIDSPACES:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️  Applying DroidSpaces options to custom.config..."
  ./scripts/config --file arch/arm64/configs/custom.config \
    --enable CONFIG_SYSCTL \
    --enable CONFIG_SYSVIPC \
    --enable CONFIG_POSIX_MQUEUE \
    --enable CONFIG_NAMESPACES \
    --enable CONFIG_PID_NS \
    --enable CONFIG_UTS_NS \
    --enable CONFIG_IPC_NS \
    --enable CONFIG_SECCOMP \
    --enable CONFIG_SECCOMP_FILTER \
    --enable CONFIG_CGROUPS \
    --enable CONFIG_CGROUP_DEVICE \
    --enable CONFIG_CGROUP_PIDS \
    --enable CONFIG_MEMCG \
    --enable CONFIG_CGROUP_SCHED \
    --enable CONFIG_FAIR_GROUP_SCHED \
    --enable CONFIG_CGROUP_FREEZER \
    --enable CONFIG_CGROUP_NET_PRIO \
    --enable CONFIG_DEVTMPFS \
    --enable CONFIG_OVERLAY_FS \
    --enable CONFIG_FW_LOADER \
    --enable CONFIG_FW_LOADER_USER_HELPER \
    --enable CONFIG_FW_LOADER_COMPRESS \
    --enable CONFIG_NET_NS \
    --enable CONFIG_VETH \
    --enable CONFIG_BRIDGE \
    --enable CONFIG_NETFILTER \
    --enable CONFIG_BRIDGE_NETFILTER \
    --enable CONFIG_NETFILTER_ADVANCED \
    --enable CONFIG_NF_CONNTRACK \
    --enable CONFIG_IP_NF_IPTABLES \
    --enable CONFIG_IP_NF_FILTER \
    --enable CONFIG_NF_NAT \
    --enable CONFIG_NF_TABLES \
    --enable CONFIG_IP_NF_TARGET_MASQUERADE \
    --enable CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
    --enable CONFIG_NETFILTER_XT_TARGET_TCPMSS \
    --enable CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
    --enable CONFIG_NF_CONNTRACK_NETLINK \
    --enable CONFIG_NF_NAT_REDIRECT \
    --enable CONFIG_IP_ADVANCED_ROUTER \
    --enable CONFIG_IP_MULTIPLE_TABLES \
    --set-val CONFIG_ANDROID_PARANOID_NETWORK n \
    --enable CONFIG_NETFILTER_XT_MATCH_COMMENT \
    --enable CONFIG_NETFILTER_XT_MATCH_STATE \
    --enable CONFIG_NETFILTER_XT_MATCH_CONNTRACK \
    --enable CONFIG_NETFILTER_XT_MATCH_MULTIPORT \
    --enable CONFIG_NETFILTER_XT_MATCH_HL \
    --enable CONFIG_NETFILTER_XT_TARGET_REJECT \
    --enable CONFIG_IP_NF_TARGET_REJECT \
    --enable CONFIG_NETFILTER_XT_TARGET_LOG \
    --enable CONFIG_IP_NF_TARGET_ULOG \
    --enable CONFIG_NETFILTER_XT_MATCH_RECENT \
    --enable CONFIG_NETFILTER_XT_MATCH_LIMIT \
    --enable CONFIG_NETFILTER_XT_MATCH_HASHLIMIT \
    --enable CONFIG_NETFILTER_XT_MATCH_OWNER \
    --enable CONFIG_NETFILTER_XT_MATCH_PKTTYPE \
    --enable CONFIG_NETFILTER_XT_MATCH_MARK \
    --enable CONFIG_NETFILTER_XT_TARGET_MARK \
    --enable CONFIG_IP_SET \
    --enable CONFIG_IP_SET_HASH_IP \
    --enable CONFIG_IP_SET_HASH_NET \
    --enable CONFIG_NETFILTER_XT_SET \
    --enable CONFIG_NETFILTER_NETLINK_QUEUE \
    --enable CONFIG_NETFILTER_NETLINK_LOG \
    --enable CONFIG_NETFILTER_XT_TARGET_NFLOG
  echo "✅ DroidSpaces options configured"
fi

cd "$KERNEL_DIR"
echo "⚙️ Applying unicodefix..."
cp "$PATCHES_DIR/common/unicode_bypass_fix_6.1-.patch" .
patch -p1 < unicode_bypass_fix_6.1-.patch
echo "✅ unicodefix applied"

if truthy "${NTSYNC:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️ Applying ntsync..."
  cp "$PATCHES_DIR/common/ntsync/ntsync_base.patch" .
  cp "$PATCHES_DIR/common/ntsync/ntsync_compat_android13-5.15.patch" .
  patch -p1 < ntsync_base.patch || true
  patch -p1 < ntsync_compat_android13-5.15.patch
  echo "✅ ntsync applied"
fi

if truthy "${NTSYNC:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️ Enabling CONFIG_NTSYNC..."
  ./scripts/config --file arch/arm64/configs/custom.config --enable CONFIG_NTSYNC
  echo "✅ ntsync config enabled"
fi

if truthy "${BBRV3:-true}"; then
  cd "$KERNEL_DIR"
  echo "⚙️ Applying BBRv3..."
  cp "$PATCHES_DIR/bbr/bbrv3-android13-5.15.patch" .
  patch -p1 < bbrv3-android13-5.15.patch
  echo "✅ BBRv3 applied"
fi

if truthy "${BBRV3:-true}"; then
  cd "$KERNEL_DIR"
  ./scripts/config --file arch/arm64/configs/custom.config \
    --enable CONFIG_TCP_CONG_ADVANCED \
    --enable CONFIG_TCP_CONG_BBR \
    --enable CONFIG_DEFAULT_BBR \
    --set-str CONFIG_DEFAULT_TCP_CONG "bbr" \
    --enable CONFIG_NET_SCH_FQ
fi

cd "$KERNEL_DIR"
echo "⚙️ Setting LOCALVERSION to '${BUILD_LOCALVERSION}'..."
./scripts/config --file arch/arm64/configs/custom.config \
  --set-str CONFIG_LOCALVERSION "${BUILD_LOCALVERSION}" \
  --set-val CONFIG_LOCALVERSION_AUTO n
echo "✅ Localversion configured"

export CONFIGS="a54x_defconfig custom.config"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-docker}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-kernel-builder}"
export PLATFORM_VERSION="${PLATFORM_VERSION:-16}"
export TARGET_SOC="${TARGET_SOC:-s5e8835}"
export DEPMOD=depmod
MAKE_PARAMS="-j$(nproc --all) ARCH=arm64 KBUILD_OUTPUT=$KERNEL_DIR/out CC=clang LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🏗️  Starting kernel build"
echo "   Variant    : $BUILD_VARIANT"
echo "   Version    : $BUILD_LOCALVERSION"
echo "   Threads    : $(nproc --all)"
echo "   Clang      : $(clang --version | head -1)"
echo "   Output     : $KERNEL_DIR/out"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "⚙️  Generating .config from $CONFIGS..."
make $MAKE_PARAMS $CONFIGS

echo ""
echo "🔨 Compiling kernel..."
make $MAKE_PARAMS

IMAGE_PATH="$KERNEL_DIR/out/arch/arm64/boot/Image"
echo "🔍 Verifying kernel image at $IMAGE_PATH..."
if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "❌ Kernel Image not found — build may have failed!" >&2
  exit 1
fi
du -sh "$IMAGE_PATH"
ls -lh "$IMAGE_PATH"

KERNEL_NAME_RAW="${BUILD_LOCALVERSION}"
KERNEL_NAME_RAW="${KERNEL_NAME_RAW#-}"
KERNEL_NAME_RELEASE="${KERNEL_NAME_RAW//Λ/A}"

echo "📦 Packaging kernel into flashable zip..."
echo "   Zip name: ${KERNEL_NAME_RELEASE}.zip"
cp "$IMAGE_PATH" "$HOME/AnyKernel3/"
cd "$HOME/AnyKernel3"
7z a "${KERNEL_NAME_RELEASE}.zip" . -xr'!*.git*' | tail -1

ZIP_PATH="$HOME/AnyKernel3/${KERNEL_NAME_RELEASE}.zip"
du -sh "$ZIP_PATH"
echo "✅ Zip created: $ZIP_PATH"

if [[ -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  cp -v "$ZIP_PATH" "$OUTPUT_DIR/"
  echo "📤 Copied to $OUTPUT_DIR/"
fi
