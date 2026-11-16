#!/bin/bash

set -euo pipefail

# Debug/helper functions
info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

show_help() {
    cat <<EOF
Usage: $0 ROOT_DIR

This script copies kernel components and modules from the build output directory.

Arguments:
  ROOT_DIR - Path to the root directory containing build outputs
EOF
}

# Validate input
if [ $# -ne 1 ]; then
    error "Please provide the root directory as an argument"
    show_help
    exit 1
fi

ROOT_DIR="$1"

# Config paths
DIST_DIR="${ROOT_DIR}/out/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user"
MTK_DIST_DIR="${ROOT_DIR}/out/dist/kernel_device_modules-6.6/mgk_64_k66.user"
CUSTOMER_MODULES_DIR="${ROOT_DIR}/out/dist/kernel_device_modules-6.6/mgk_64_k66_customer_modules_install.user"
STRIP_BIN="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-strip"

# Validate directories exist
for dir in "$DIST_DIR" "$MTK_DIST_DIR" "$CUSTOMER_MODULES_DIR"; do
    if [ ! -d "$dir" ]; then
        error "Directory not found: $dir"
        exit 1
    fi
done

# Create target directories if they don't exist
for TARGET in system_dlkm vendor_dlkm vendor_ramdisk; do
    mkdir -p "$TARGET"
done

# Kernel operations
# Resolve each packaged module from this build. Keep the original output
# precedence: MTK-configured modules override generic GKI copies on collisions.
module_source() {
    local name="$1"
    local target="$2"
    local root candidate selected=""

    for root in "$DIST_DIR" "$CUSTOMER_MODULES_DIR" "$MTK_DIST_DIR"; do
        [ -d "$root" ] || continue
        while IFS= read -r -d '' candidate; do
            selected="$candidate"
        done < <(find "$root" -type f -name "$name" -print0)
    done

    if [ -z "$selected" ]; then
        error "No module artifact for $name in this build ($target)"
        return 1
    fi

    printf '%s\n' "$selected"
}

is_removed_module() {
    case "$1/$2" in
        system_dlkm/tls.ko|vendor_dlkm/iommu_engine.ko|vendor_dlkm/iommu_test.ko)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Validate artifacts and signing inputs before modifying the prebuilt tree.
info "Checking module artifacts..."
shopt -s nullglob
for TARGET in system_dlkm vendor_dlkm vendor_ramdisk; do
    for MODULE_FILE in "$TARGET"/*.ko; do
        MODULE_NAME="$(basename "$MODULE_FILE")"
        if is_removed_module "$TARGET" "$MODULE_NAME"; then
            continue
        fi
        if ! module_source "$MODULE_NAME" "$TARGET" >/dev/null; then
            exit 1
        fi
    done
done
shopt -u nullglob
SI_HAPTIC_SOURCE="$(module_source si_haptic.ko vendor_dlkm)"

if [ ! -f "$DIST_DIR/Image.lz4" ]; then
    error "Missing Image.lz4 from this build"
    exit 1
fi
if [ ! -x "$STRIP_BIN" ]; then
    error "llvm-strip not found: $STRIP_BIN"
    exit 1
fi

SIGN_CERT="$DIST_DIR/certs/signing_key.x509"
MODINFO_BIN="$(command -v modinfo || true)"
if [ -z "$MODINFO_BIN" ] || [ ! -f "$SIGN_CERT" ]; then
    error "modinfo or the kernel signing certificate is missing"
    exit 1
fi
SIGN_CERT_PUB_HASH="$(openssl x509 -in "$SIGN_CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
SIGNING_ROOT="$ROOT_DIR/out/bazel/output_user_root/output_base/sandbox/sandbox_stash/KernelModule"
SIGN_KEY=""
if [ -d "$SIGNING_ROOT" ]; then
    while IFS= read -r -d '' CANDIDATE_KEY; do
        CANDIDATE_PUB_HASH="$(openssl pkey -in "$CANDIDATE_KEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
        if [ "$CANDIDATE_PUB_HASH" = "$SIGN_CERT_PUB_HASH" ]; then
            SIGN_KEY="$CANDIDATE_KEY"
            break
        fi
    done < <(find "$SIGNING_ROOT" -type f -path '*/kernel-6.6/mtk_signing_key.pem' -print0)
fi
if [ -z "$SIGN_KEY" ]; then
    error "Could not find the private key matching this kernel's module certificate"
    exit 1
fi

SIGN_FILE="$ROOT_DIR/out/klee-sign-file"
if [ ! -x "$SIGN_FILE" ]; then
    mkdir -p "$ROOT_DIR/out"
    if ! cc -O2 -o "$SIGN_FILE" "$ROOT_DIR/kernel-6.6/scripts/sign-file.c" -lcrypto; then
        error "Failed to build the module signing utility"
        exit 1
    fi
fi

MKDTIMG="$ROOT_DIR/prebuilts/kernel-build-tools/linux-x86/bin/mkdtimg"
if [ ! -x "$MKDTIMG" ]; then
    MKDTIMG="$(command -v mkdtimg || true)"
fi
DT_DIR="$MTK_DIST_DIR/mediatek"
if [ -z "$MKDTIMG" ] || [ ! -x "$MKDTIMG" ]; then
    error "mkdtimg not found; cannot synchronize DTB/DTBO"
    exit 1
fi
if [ ! -f "$DT_DIR/xiaomi_mt6899_common.dtb" ] || [ ! -f "$DT_DIR/klee.dtb" ]; then
    error "Klee DTB build outputs are incomplete in $DT_DIR"
    exit 1
fi

DT_STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$DT_STAGE_DIR"' EXIT
if ! "$MKDTIMG" create "$DT_STAGE_DIR/mt6899.dtb" --page_size=2048 "$DT_DIR/xiaomi_mt6899_common.dtb" >/dev/null; then
    error "Failed to stage dtb/mt6899.dtb"
    exit 1
fi
if ! "$MKDTIMG" create "$DT_STAGE_DIR/dtbo.img" --page_size=2048 "$DT_DIR/klee.dtb" >/dev/null; then
    error "Failed to stage dtbo.img"
    exit 1
fi

info "Copying kernel image..."
cp "$DIST_DIR/Image.lz4" ./ || error "Failed to copy Image.lz4"
chmod -x Image.lz4

info "Synchronizing system_dlkm, vendor_dlkm, and vendor_ramdisk modules..."
shopt -s nullglob
for TARGET in system_dlkm vendor_dlkm vendor_ramdisk; do
    for MODULE_FILE in "$TARGET"/*.ko; do
        MODULE_NAME="$(basename "$MODULE_FILE")"
        if is_removed_module "$TARGET" "$MODULE_NAME"; then
            continue
        fi
        SOURCE="$(module_source "$MODULE_NAME" "$TARGET")"
        cp -f -- "$SOURCE" "$MODULE_FILE"
    done
done
shopt -u nullglob

cp -f -- "$SI_HAPTIC_SOURCE" vendor_dlkm/si_haptic.ko
rm -f system_dlkm/tls.ko vendor_dlkm/iommu_engine.ko vendor_dlkm/iommu_test.ko
sed -i '/^tls[.]ko$/d' modules.load.system
sed -i '/^touch_boost[.]ko$/d' modules.load.vendor
if ! grep -Fxq "si_haptic.ko" modules.load.vendor; then
    echo "si_haptic.ko" >> modules.load.vendor
fi

# Strip debug information, then sign with the certificate embedded in Image.
# This preserves compact modules without discarding their valid signatures.
info "Stripping and signing modules..."
for TARGET in system_dlkm vendor_dlkm vendor_ramdisk; do
    for MODULE_FILE in "$TARGET"/*.ko; do
        MODULE_NAME="$(basename "$MODULE_FILE")"
        if is_removed_module "$TARGET" "$MODULE_NAME"; then
            continue
        fi
        SOURCE="$(module_source "$MODULE_NAME" "$TARGET")"
        MODULE_HASH="$("$MODINFO_BIN" -F sig_hashalgo "$SOURCE")"
        if [ -z "$MODULE_HASH" ]; then
            error "Build artifact $SOURCE has no module signature hash"
            exit 1
        fi
        if ! "$STRIP_BIN" --strip-debug "$MODULE_FILE"; then
            error "Failed to strip $MODULE_FILE"
            exit 1
        fi
        if ! "$SIGN_FILE" "$MODULE_HASH" "$SIGN_KEY" "$SIGN_CERT" "$MODULE_FILE"; then
            error "Failed to sign $MODULE_FILE"
            exit 1
        fi
    done
done

validate_load_list() {
    local list="$1"
    local module_dir="$2"
    local module
    while IFS= read -r module || [ -n "$module" ]; do
        [ -z "$module" ] && continue
        if [[ "$module" == "#"* ]]; then
            continue
        fi
        if [ ! -f "$module_dir/$module" ]; then
            error "$list references missing module $module_dir/$module"
            return 1
        fi
    done < "$list"
}

validate_load_list modules.load.system system_dlkm
validate_load_list modules.load.vendor vendor_dlkm
validate_load_list modules.load.vendor_ramdisk vendor_ramdisk
validate_load_list modules.load.recovery vendor_ramdisk

mkdir -p dtb
cp -f -- "$DT_STAGE_DIR/mt6899.dtb" dtb/mt6899.dtb
cp -f -- "$DT_STAGE_DIR/dtbo.img" dtbo.img
info "Wrote dtb/mt6899.dtb and dtbo.img"

info "Operation completed successfully."
