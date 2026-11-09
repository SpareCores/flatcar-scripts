#!/usr/bin/env bash
# Generate /usr/share/licenses/licenses.json.bz2 and the extra SLSA files for the final image.
#
# Calls upstream write_licenses()/insert_licenses() (build_library/build_image_util.sh)
# -- the same functions prod_image_util.sh uses -- over a rootfs whose /var/db/pkg
# is the union of the base image and the built-in sysexts named as arguments.
# That mirrors upstream: sysext_prod_builder overlays each built-in sysext's
# <name>_pkginfo.raw onto the base and runs a single write_licenses pass
# (prod_image_util.sh:103-117); extra sysexts aren't covered.
set -eo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

. "${SRCDIR}/lib/lib.sh"
create_configroot "$FLATCAR_UPDATE_GROUP"
set_image_profile "$FLATCAR_IMAGE_PROFILE"   # build_image_util.sh:156

root="${BUILDROOT:?BUILDROOT must be set by mkosi}"

# shellcheck source=tools/bin/sdk-env.sh
# . "${SRCDIR:?}/tools/bin/sdk-env.sh"

outdir="${SRCDIR}/mkosi.output"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Union pkgdb: the image's own, plus each built-in sysext's saved one.
merged="${work}/merged"
mkdir -p "${merged}/var/db"
cp -a "${root}/var/db/pkg" "${merged}/var/db/pkg"

for name in "$@"; do
    d="${outdir}/${name}-sysext-pkgdb"
    [[ -d "${d}/var/db/pkg" ]] || { echo "[licenses] ERROR: ${d} missing" >&2; exit 1; }
    cp -a "${d}/var/db/pkg"/. "${merged}/var/db/pkg/"
    echo "[licenses] merged ${name}"
done

json="${work}/licenses.json"
write_licenses "${merged}" "${json}"
insert_licenses "${json}" "${root}"
# Same spot as prod_image_util.sh:126: SLSA for packages only in the initrd/ESP.
insert_extra_slsa "${root}"

pkgs=$(grep -c '"project"' "${json}" 2>/dev/null || true)
echo "[licenses] wrote licenses.json.bz2 (${pkgs:-0} packages)"
