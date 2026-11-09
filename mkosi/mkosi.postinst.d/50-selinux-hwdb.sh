#!/usr/bin/env bash
# SELinux policy and the hwdb, before /etc is populated and frozen.
. "${SRCDIR}/lib/postinst.sh"

# build_library/build_image_util.sh finish_image():648-651
# Build the selinux policy
if pkg_use_enabled coreos-base/coreos selinux; then
  mkosi-chroot bash -c "cd /usr/share/selinux/mcs && semodule -s mcs -i *.pp"
fi

# mkosi's run_hwdb() moved the hwdb to /usr and deleted /etc/udev/hwdb.bin;
# restore what the systemd ebuild ships (udevadm hwdb --update into /etc).
mkosi-chroot systemd-hwdb update
rm -f "${root_fs_dir}/usr/lib/udev/hwdb.bin"
