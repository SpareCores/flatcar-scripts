#!/usr/bin/env bash
# finish_image()'s /etc: populate it via tmpfiles, then label it.
. "${SRCDIR}/lib/postinst.sh"

# Populate /etc via tmpfiles before freezing it into /usr/share/flatcar/etc
# tmpfiles needs all users/groups in /etc/passwd first; seed them from
# baselayout
for dbfile in passwd shadow group gshadow; do
  cp -f "${root_fs_dir}"/usr/share/baselayout/"${dbfile}" "${root_fs_dir}"/etc/
done

# run systemd-tmpfiles inside chroot because Flatcar ships systemd 258 and its
# d$/L$/L? modifiers break the older host binary
mkosi-chroot /usr/bin/systemd-tmpfiles \
  --create --remove --boot --exclude-prefix=/dev
for dbfile in passwd shadow group gshadow; do
  rm -f "${root_fs_dir}"/etc/"${dbfile}"
done
"${root_fs_dir}"/usr/sbin/flatcar-tmpfiles "${root_fs_dir}"
# Delete the tmpfiles rules we just used for /etc (L/d/D/C entries cause overlay
# upcopies). First save the paths a rule would recreate to etc-no-whiteouts, so we
# can guarantee no overlay whiteout hides them (e.g. /etc/resolv.conf).
grep -Ph '^[fcCdDLvqQpb][-=~^!+]*[ \t]*/etc' "${root_fs_dir}"/usr/lib/tmpfiles.d/* | grep -oP '/etc[^ \t]*' > "${root_fs_dir}"/usr/share/flatcar/etc-no-whiteouts
sed -i '/^[CdDL][-=~^!]*[ \t]*\/etc\//d' "${root_fs_dir}"/usr/lib/tmpfiles.d/*

# build_library/build_image_util.sh finish_image():681-693
# SELinux: Label the root filesystem for using 'file_contexts'.
# The labeling has to be done before moving /etc to /usr/share/flatcar/etc to prevent wrong labels for these files and as
# the relabeling on boot would cause upcopies in the overlay.
if pkg_use_enabled coreos-base/coreos selinux; then
  # setfiles from version 3.11 requires the passed path to have no symlinks
  real_root_fs_dir=$(realpath "${root_fs_dir}")
  # Upstream only labels /etc: labeling / or /usr "breaks the system".
  setfiles -Dv -r "${real_root_fs_dir}" "${real_root_fs_dir}"/etc/selinux/mcs/contexts/files/file_contexts "${real_root_fs_dir}"/etc
fi

# Set /etc/{g,}shadow group to the shadow group so unix_chkpwd/chage/expiry work.
# Belongs in an ebuild, but baselayout installs these and we don't want more deps.
chgrp \
    --reference="${root_fs_dir}/usr/bin/chage" \
    "${root_fs_dir}"/{etc,usr/share/baselayout}/{g,}shadow
