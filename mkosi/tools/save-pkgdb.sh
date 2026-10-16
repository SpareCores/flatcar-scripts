#!/usr/bin/env bash
# Save this image's portage pkgdb to the shared output dir.
#
# Sysexts ship only /usr (Overlay=yes), so their /var/db/pkg -- and with it every
# package's LICENSE/DESCRIPTION/HOMEPAGE/SRC_URI/CONTENTS -- is discarded from the
# final DDI. Upstream keeps it out-of-band as <name>_pkginfo.raw
# (build_sysext --generate_pkginfo) and overlays those back together before
# generating the license manifest (sysext_prod_builder). We do the same thing with
# a plain directory copy: run this as a postinst, then the top-level postinst
# merges base + every sysext pkgdb and runs write_licenses over the union.
#
# Only entries NOT already in the base tree are copied, so each sysext contributes
# exactly the packages it adds.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

root="${BUILDROOT:?BUILDROOT must be set by mkosi}"
# mkosi exports SUBIMAGE for every non-main image.
image="${SUBIMAGE:?SUBIMAGE must be set by mkosi}"
src="${root}/var/db/pkg"
dst="${SRCDIR:?}/mkosi.output/${image}-pkgdb"

rm -rf "${dst}"
[[ -d "${src}" ]] || { echo "[pkgdb] ${image}: no /var/db/pkg, nothing to save"; exit 0; }

base_pkgdb="${SRCDIR}/mkosi.output/base/var/db/pkg"
count=0
while IFS= read -r pkg; do
    # Skip packages already provided by the base image.
    [[ -d "${base_pkgdb}/${pkg}" ]] && continue
    mkdir -p "${dst}/${pkg%/*}"
    cp -a "${src}/${pkg}" "${dst}/${pkg}"
    count=$((count + 1))
done < <(cd "${src}" && find . -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | sort)

echo "[pkgdb] ${image}: saved ${count} package(s) to $(basename "${dst}")"
