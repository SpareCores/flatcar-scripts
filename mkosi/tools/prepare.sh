#!/bin/bash
# Shared prepare hook for every sub-image. This has to be called from every (sub-)image
#
# PrepareScripts=%D/tools/prepare.sh
#
# When Distribution=custom, mkosi doesn't install any packages and expects the
# prepare script to install the whole image, so Packages= / RemovePackages= are
# parsed but never acted on. They do survive into the script config JSON, so
# read them back and drive the mkosi-* helpers ourselves.

set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

[ "$1" = final ] || exit 0

. "${SRCDIR}/lib/lib.sh"

create_configroot "$FLATCAR_UPDATE_GROUP"
set_image_profile "$FLATCAR_IMAGE_PROFILE"   # build_image_util.sh:156


echo "prepare[base]: pre-install steps"

mkosi_config_read_array() { jq -r --arg k "$1" '.[$k] // [] | .[]' "$MKOSI_CONFIG"; }
image="$(jq -r '.Image // "main"' "$MKOSI_CONFIG")"
# Not mkosi's build-overlay semantics; source builds go through
# FLATCAR_SOURCE_BUILD below, which builds the Packages= closure itself.
for setting in BuildPackages VolatilePackages; do
    mapfile -t unsupported < <(mkosi_config_read_array "$setting")
    if [ "${#unsupported[@]}" -gt 0 ]; then
        echo "prepare[$image]: $setting= is not currently supported in Flatcar mkosi setup" >&2
        exit 1
    fi
done

mapfile -t install < <(mkosi_config_read_array Packages)
mapfile -t remove  < <(mkosi_config_read_array RemovePackages)

# Pass 1: build anything in the Packages= closure that has no current binpkg,
# into the board sysroot, caching the result in PKGDIR. --usepkg (in
# emerge_from_source) reuses up-to-date binpkgs, so this is cheap once warm.
# Pass 2 below stays --usepkgonly: that is what keeps compilers and DEPENDs out
# of the image. Set FLATCAR_SOURCE_BUILD=0 for a strictly binpkg-only build.
if [ "${FLATCAR_SOURCE_BUILD:-1}" = 1 ] && [ "${#install[@]}" -gt 0 ]; then
    echo "prepare[$image]: source build enabled, emerging ${install[*]} into ${BOARD_ROOT}"
    emerge_from_source "${install[@]}"
fi

[ "${#install[@]}" -gt 0 ] && mkosi-install "${install[@]}"
[ "${#remove[@]}"  -gt 0 ] && mkosi-remove  "${remove[@]}"

# Flatcar installs the kernel to /usr/boot/vmlinuz-<kver>, but mkosi's
# gen_kernel_images() only looks in /usr/lib/modules/<kver>/vmlinuz*, so
# Bootable=yes fails with "A bootable image was requested but no kernel was
# found". The dropped mkosi fork did this copy in flatcar.py; do it here.
# (The base postinst separately copies it to /boot/flatcar/vmlinuz-a, which
# is what grub actually loads.)
for kver_dir in "${BUILDROOT}"/usr/lib/modules/*/; do
    [ -d "${kver_dir}" ] || continue
    kver="$(basename "${kver_dir}")"
    for kt in vmlinuz vmlinux; do
        src="${BUILDROOT}/usr/boot/${kt}-${kver}"
        [ -e "${src}" ] || src="${BUILDROOT}/usr/boot/${kt}"
        [ -e "${src}" ] || continue
        [ -e "${kver_dir}${kt}" ] || cp -a "${src}" "${kver_dir}${kt}"
    done
done

exit 0
