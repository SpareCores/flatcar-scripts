#!/usr/bin/env bash
# Emit the upstream qemu launcher next to image.raw by calling upstream's own
# _write_qemu_uefi_conf() (build_library/vm_image_util.sh) -- the same function
# image_to_vm.sh uses -- rather than reimplementing its sed/cp logic here.
#
# It is driven entirely by variables: VM_IMG_TYPE selects the IMG_* option set,
# _dst_name() derives names from $VM_SRC_IMG, _dst_dir() from $VM_DST_IMG, and
# _write_qemu_common() substitutes VM_NAME/VM_MEMORY/VM_BOARD into
# qemu_template.sh. Upstream names images <prefix>_image.bin and strips that
# suffix, so point VM_SRC_IMG at a matching pseudo-name to get
# flatcar_production_qemu_uefi.sh out.
#
# This exists because `mkosi vm` cannot run outside the SDK: mkosi.conf's
# ExtraSearchPaths= point at SDK-only paths (/build/<board>, the ebuild repos)
# and mkosi validates their existence while PARSING the config, before any
# --extra-search-path= override applies. The generated script is plain qemu and
# runs on the host, where KVM is.
#
# Runs as a post-output script, so image.raw is already in $OUTPUTDIR.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

# Post-output scripts get no ARTIFACTDIR from mkosi. lib.sh needs it only for
# BUILD_DIR (configroot, emerge), which nothing here uses.
export ARTIFACTDIR="${ARTIFACTDIR:-$(mktemp -d)}"
. "${SRCDIR}/lib/lib.sh"

outdir="${OUTPUTDIR:?OUTPUTDIR must be set by mkosi}"
img="${outdir}/image.raw"
# [[ -f "${img}" ]] || { echo "[qemu-script] ${img} not found, skipping"; exit 0; }

# shellcheck source=tools/bin/sdk-env.sh
# . "${SRCDIR}/tools/bin/sdk-env.sh"

util="${SDK_SCRIPTS}/build_library/vm_image_util.sh"
[[ -f "${util}" ]] || { echo "[qemu-script] missing ${util}, skipping"; exit 0; }

# Upstream expects the image to sit next to the script it generates, named
# <prefix>_image.bin: _dst_name() derives every output name from $VM_SRC_IMG,
# and _write_qemu_conf points VM_IMAGE= at $(basename $VM_DST_IMG). Link
# image.raw to BOTH so the names resolve and the launcher finds the disk.
src_img="${outdir}/flatcar_production_image.bin"
dst_img="${outdir}/flatcar_production_qemu_uefi_image.bin"
ln -sf "$(basename "${img}")" "${src_img}"
ln -sf "$(basename "${img}")" "${dst_img}"
# _write_qemu_uefi_conf also writes the Secure Boot launcher, which expects this name.
ln -sf "$(basename "${img}")" "${outdir}/flatcar_production_qemu_uefi_secure_image.bin"


VM_IMG_TYPE=qemu_uefi
VM_SRC_IMG="${src_img}"
VM_DST_IMG="${dst_img}"
VM_NAME=flatcar_production_qemu_uefi
VM_README="${outdir}/flatcar_production_qemu_uefi_README"
VM_GENERATED_FILES=()

_write_qemu_uefi_conf

script="${outdir}/flatcar_production_qemu_uefi.sh"
if [[ ! -x "${script}" ]]; then
    echo "[qemu-script] WARNING: ${script} was not generated" >&2
    exit 0
fi

echo "[qemu-script] wrote flatcar_production_qemu_uefi.sh (run: ./flatcar_production_qemu_uefi.sh -nographic)"
