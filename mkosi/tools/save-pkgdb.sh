#!/usr/bin/env bash
# Save this image's portage pkgdb to the shared output dir.
#
# Sysexts ship only /usr (Overlay=yes), so their /var/db/pkg -- and with it every
# package's LICENSE/DESCRIPTION/HOMEPAGE/SRC_URI/CONTENTS -- is discarded from the
# final DDI. Upstream keeps it out-of-band as <name>_pkginfo.raw
# (build_sysext --generate_pkginfo) and overlays those back together before
# generating the license manifest (sysext_prod_builder). We do the same thing with
# a plain directory tree, <image>-pkgdb/var/db/pkg: the top-level postinst merges
# base + every sysext pkgdb and runs write_licenses over the union, and a sysext
# built on another one lists that one's pkgdb in BaseTrees= (as --base_pkginfo).
#
# Only entries NOT already in a lower layer (any BaseTrees= entry with a pkgdb)
# are copied, so each sysext contributes exactly the packages it adds.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

root="${BUILDROOT:?BUILDROOT must be set by mkosi}"
# mkosi exports SUBIMAGE for every non-main image.
image="${SUBIMAGE:?SUBIMAGE must be set by mkosi}"
src="${root}/var/db/pkg"
dst="${SRCDIR:?}/mkosi.output/${image}-pkgdb"

rm -rf "${dst}"
# Created even when empty: dependent sysexts list it in BaseTrees=.
mkdir -p "${dst}/var/db/pkg"
[[ -d "${src}" ]] || { echo "[pkgdb] ${image}: no /var/db/pkg, nothing to save"; exit 0; }

lower_pkgdbs=()
while IFS= read -r tree; do
    lower="${SRCDIR}/mkosi.output/${tree##*/}/var/db/pkg"
    [[ -d "${lower}" ]] && lower_pkgdbs+=("${lower}")
done < <(jq -r '.BaseTrees // [] | .[]' "${MKOSI_CONFIG}")

count=0
while IFS= read -r pkg; do
    for lower in "${lower_pkgdbs[@]}"; do
        [[ -d "${lower}/${pkg}" ]] && continue 2
    done
    mkdir -p "${dst}/var/db/pkg/${pkg%/*}"
    cp -a "${src}/${pkg}" "${dst}/var/db/pkg/${pkg}"
    count=$((count + 1))
done < <(cd "${src}" && find . -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | sort)

echo "[pkgdb] ${image}: saved ${count} package(s) to $(basename "${dst}")"
