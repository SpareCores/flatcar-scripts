#!/usr/bin/env bash
# Run upstream's build_library/sysext_mangle_<name>, as build_sysext
# --manglefs_script does. As a finalize script it sees only the overlay's
# upper layer, which is what build_sysext passes after unmounting its overlay.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

. "${SRCDIR}/lib/lib.sh"

name="$(jq -r '.Output' "${MKOSI_CONFIG}")"
mangle="${BUILD_LIBRARY_DIR}/sysext_mangle_${name}"
[[ -x "${mangle}" ]] || { echo "[mangle] ${name}: no ${mangle##*/}"; exit 0; }
"${mangle}" "${BUILDROOT}"
