#!/usr/bin/env bash
# Turn an oem-<flavor> profile's disk image ($1) into its vendor format (azure
# vhd, gce tar.gz, qemu_uefi qcow2 + launcher, ...) with image_to_vm.sh's own
# write_vm_disk/write_vm_conf/write_vm_bundle. mkosi already did the rest of
# image_to_vm.sh: disk layout (profile repart drop-in) and OEM partition
# (mkosi.postinst.d/06-oem.sh).
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

# Post-output scripts get no ARTIFACTDIR; lib.sh needs it only for BUILD_DIR.
export ARTIFACTDIR="${ARTIFACTDIR:-$(mktemp -d)}"
. "${SRCDIR}/lib/lib.sh"

img="${1:?usage: write-vm-image.sh DISK_IMAGE}"
outdir="$(dirname "${img}")"

set_vm_type "${FLATCAR_VM_TYPE:?FLATCAR_VM_TYPE must be set by the oem profile}" \
  || die "Unknown FLATCAR_VM_TYPE=${FLATCAR_VM_TYPE}"

# set_vm_paths, for the name build_image gives the production image; only its
# name is used, to derive the vendor file names.
src_name=flatcar_production_image.bin
VM_SRC_IMG="${outdir}/${src_name}"
VM_DST_IMG="${outdir}/$(_src_to_dst_name "${src_name}" "_image.$(_disk_ext)")"
VM_TMP_DIR="$(mktemp -d)"
VM_TMP_IMG="${VM_TMP_DIR}/disk_image.bin"
VM_TMP_ROOT="${VM_TMP_DIR}/rootfs"
VM_NAME="$(_src_to_dst_name "${src_name}" "")-${FLATCAR_VERSION}"
VM_NAME="${VM_NAME//./-}"
VM_NAME="${VM_NAME//+/-}"
VM_README="${outdir}/$(_src_to_dst_name "${src_name}" ".README")"
VM_GENERATED_FILES=()

cp --reflink=auto --sparse=always "${img}" "${VM_TMP_IMG}"
# write_vm_disk unmounts VM_TMP_ROOT, where image_to_vm.sh has the image's
# partitions mounted; mkosi did that work already, so mount a stand-in to keep
# disk_util umount from failing with a traceback.
mkdir -p "${VM_TMP_ROOT}"
mount -t tmpfs vm-tmp-root "${VM_TMP_ROOT}"
write_vm_disk
write_vm_conf
write_vm_bundle
rm -rf "${VM_TMP_DIR}"

printf '[vm-image] wrote %s\n' "${VM_GENERATED_FILES[@]##*/}"
