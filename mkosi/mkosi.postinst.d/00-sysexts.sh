#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Bake the built-in sysexts into the disk. Mirrors upstream
# build_library/sysext_prod_builder create_prod_sysext(): each signed DDI is
# installed under the verity'd /usr at
#   /usr/share/flatcar/sysext/<name>.raw
# with a merge symlink
#   /etc/extensions/<name>.raw -> /usr/share/flatcar/sysext/<name>.raw
# so systemd-sysext merges them unconditionally at boot (no download, no
# enabled-sysext.conf toggle — that path is for version-coupled downloadable
# sysexts, not these baked-in defaults).
#
# The DDIs are built by the containerd-flatcar-sysext / docker-flatcar-sysext
# sub-images (top-level Dependencies=), landing in the shared mkosi.output/ that
# is bind-mounted at $SRCDIR.
. "${SRCDIR}/lib/postinst.sh"

# Names must match the sub-images' Output=/ImageId=.
builtin_sysexts="$(sdk_base_sysexts | cut -d'|' -f1)"
mapfile -t builtin_sysexts <<<"${builtin_sysexts}"

sysext_dir="${root_fs_dir}/usr/share/flatcar/sysext"
ext_dir="${root_fs_dir}/etc/extensions"
install -d -m 0755 "${sysext_dir}" "${ext_dir}"

for name in "${builtin_sysexts[@]}"; do
    src="${SRCDIR}/mkosi.output/${name}.raw"
    if [[ ! -f "${src}" ]]; then
        echo "[builtin-sysext] ERROR: ${src} not found — was the ${name}-sysext sub-image built?" >&2
        exit 1
    fi

    install -m 0644 "${src}" "${sysext_dir}/${name}.raw"
    ln -sf "/usr/share/flatcar/sysext/${name}.raw" "${ext_dir}/${name}.raw"
    echo "[builtin-sysext] baked ${name}.raw into /usr + /etc/extensions symlink"
done
