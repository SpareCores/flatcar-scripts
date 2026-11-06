#!/usr/bin/env bash
# The tail of build_sysext for every sysext: run upstream's
# build_library/sysext_mangle_<name> (--manglefs_script), then write the
# extension-release, replacing mkosi's (which adds SYSEXT_LEVEL/SYSEXT_SCOPE and
# uses ImageVersion= as SYSEXT_VERSION_ID). As a finalize script it sees only the
# overlay's upper layer, which is what build_sysext passes after unmounting its
# overlay.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

. "${SRCDIR}/lib/lib.sh"

SYSEXT_ID="$(jq -r '.Output' "${MKOSI_CONFIG}")"
mangle="${BUILD_LIBRARY_DIR}/sysext_mangle_${SYSEXT_ID}"
if [[ -x "${mangle}" ]]; then
  "${mangle}" "${BUILDROOT}"
else
  echo "[mangle] ${SYSEXT_ID}: no ${mangle##*/}"
fi

# build_sysext:236-240, 293-305 from here on.
ARCH="$(jq -r '.Architecture' "${MKOSI_CONFIG}")"
mapfile -t packages < <(jq -r '.Packages[]' "${MKOSI_CONFIG}")
FLATCAR_VERSION_ID="$(. "${SRCDIR}/mkosi.output/base/usr/lib/os-release"; echo "${VERSION_ID}")"

# If there's only one package, grab its metadata for the sysext.
unset PVR HOMEPAGE SYSEXT_NAME
if [[ ${#packages[@]} -eq 1 ]]; then
  pkgdb="${SRCDIR}/mkosi.output/${SUBIMAGE:?}-pkgdb"
  CPV=$(portageq best_version "${pkgdb}" "${packages[0]}")
  IFS=$'\n' read -r -d '' PVR HOMEPAGE SYSEXT_NAME < <(portageq metadata "${pkgdb}" installed "${CPV}" PVR HOMEPAGE SYSEXT_NAME; printf '\0')
fi

grep . <<EOF | install -m0644 -D /dev/stdin "${BUILDROOT}/usr/lib/extension-release.d/extension-release.${SYSEXT_ID}"
ID='flatcar'
${VERSION_FIELD_OVERRIDE:-VERSION_ID}=${FLATCAR_VERSION_ID@Q}
ARCHITECTURE=${ARCH@Q}
EXTENSION_RELOAD_MANAGER=1
SYSEXT_ID=${SYSEXT_ID@Q}
${SYSEXT_NAME:+SYSEXT_NAME=${SYSEXT_NAME@Q}}
${PVR:+SYSEXT_VERSION_ID=${PVR@Q}}
${HOMEPAGE:+SYSEXT_HOME_URL=${HOMEPAGE@Q}}
SYSEXT_BUG_REPORT_URL='https://issues.flatcar.org'
EOF
