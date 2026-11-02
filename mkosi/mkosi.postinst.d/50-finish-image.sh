#!/usr/bin/env bash
# Main image: create_prod_image()'s clean-ups after the sysext snapshot plus
# finish_image()'s /etc handling. Runs after mkosi.postinst (builtin sysexts,
# licenses), the same order as upstream.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

# shellcheck source=lib/lib.sh
. "${SRCDIR}/lib/lib.sh"

root_fs_dir="${BUILDROOT:?BUILDROOT must be set by mkosi}"

# build_library/prod_image_util.sh create_prod_image():141-162
# clean-ups of things we do not need
rm "${root_fs_dir}"/etc/csh.env
rm -rf "${root_fs_dir}"/etc/env.d

mv "${root_fs_dir}"/etc/profile.env \
    "${root_fs_dir}"/usr/share/baselayout/profile.env

# Move the ld.so configs into /usr so they can be symlinked from /
mv "${root_fs_dir}"/etc/ld.so.conf "${root_fs_dir}"/usr/lib
mv "${root_fs_dir}"/etc/ld.so.conf.d "${root_fs_dir}"/usr/lib

ln --symbolic ../usr/lib/ld.so.conf "${root_fs_dir}"/etc/ld.so.conf

# Add a tmpfiles rule that symlink ld.so.conf from /usr into /
cat > "${root_fs_dir}/usr/lib/tmpfiles.d/baselayout-ldso.conf" <<'EOF'
L+  /etc/ld.so.conf     -   -   -   -   ../usr/lib/ld.so.conf
EOF

# TODO use FEATURES=splitdebug + INSTALL_MASK instead (as upstream Flatcar)
rm -rf "${root_fs_dir}/usr/lib/debug"
rm -rf "${root_fs_dir}/usr/include"
rm -rf "${root_fs_dir}/usr/lib64/cmake" "${root_fs_dir}/usr/lib64/pkgconfig"

# build_library/prod_image_util.sh create_prod_image():164-171
# `local` dropped: this runs at script scope, not in a function.
bad_pam_files=()
mapfile -t -d '' bad_pam_files < <(find "${root_fs_dir}"/etc/security "${root_fs_dir}"/etc/pam.d ! -type d ! -name '.keep*' -print0)
if [[ ${#bad_pam_files[@]} -gt 0 ]]; then
  error "Found following PAM config files: ${bad_pam_files[@]#"${root_fs_dir}"}"
  error "Expected them to be either removed or, better, vendored (/etc/pam.d files should be in /usr/lib/pam, /etc/security files should be in /usr/lib/pam/security)."
  error "Vendoring can be done with vendorize_pam_files inside a post_src_install hook for the package that installed the config file."
  die "PAM config errors spotted"
fi

# build_library/prod_image_util.sh create_prod_image():173-174
# Remove source locale data, only need to ship the compiled archive.
rm -rf "${root_fs_dir}"/usr/share/i18n/

# Move the kernel to the /boot partition and mark it as A-slot
mkdir -p "${root_fs_dir}/boot/flatcar/"
cp "${root_fs_dir}/usr/boot/vmlinuz" \
     "${root_fs_dir}/boot/flatcar/vmlinuz-a"
rm "${root_fs_dir}/usr/boot/vmlinuz"*

found=""
# check if there are any dinamically allocated user IDs
# we want to forbid "-", "X:-" (.*:-), "-:X" (-:.*), "/X" (/.*)
found=$({ grep '^[ug]' "${root_fs_dir}"/usr/lib/sysusers.d/*.conf || true ; } | awk '{print $3}' | { grep -x -- "-\|.*:-\|-:.*\|/.*" || true ; })
if [ "${found}" != "" ]; then
  die "Found dynamic ID allocation instead of hardcoded ID in /usr/lib/sysusers.d/*.conf (third column must not use '-', 'X:-', '-:X', or '/path')"
fi
# Create users and groups from /etc/ via systemd-sysusers, then fold new
# entries into /usr/share/baselayout so they live in /usr
systemd-sysusers --root="${root_fs_dir}"
for databasefile in passwd group shadow gshadow; do
  newentries=$(comm -23 <(cut -d ":" -f 1 "${root_fs_dir}/etc/${databasefile}" | sort) <(cut -d ":" -f 1 "${root_fs_dir}/usr/share/baselayout/${databasefile}" | sort))
  for newentry in ${newentries}; do
    grep "^${newentry}:" "${root_fs_dir}/etc/${databasefile}" | tee -a "${root_fs_dir}/usr/share/baselayout/${databasefile}"
  done
  rm -f "${root_fs_dir}/etc/${databasefile}" "${root_fs_dir}/etc/${databasefile}-"
done
# Generate tmpfiles rules that recreate the /var skeleton at boot. Ignore paths
# already covered by existing tmpfiles configs, and
ignores=() allowed_users=() allowed_groups=()
mapfile -t ignores < <(awk '/^[dDfFL]/ {print "--ignore=" $2}' \
                           "${root_fs_dir}"/usr/lib/tmpfiles.d/*.conf)
# extract COPY_GROUPS/COPY_USERS from the gen_tmpfiles.py
mapfile -t allowed_users < <(grep '^COPY_USERS=' "${root_fs_dir}/sbin/flatcar-tmpfiles" | sed -e 's/.*="\([^"]*\)"/\1/' | tr '|' '\n' | sed -e 's/^/--allow-user=/')
mapfile -t allowed_groups < <(grep '^COPY_GROUPS=' "${root_fs_dir}/sbin/flatcar-tmpfiles" | sed -e 's/.*="\([^"]*\)"/\1/' | tr '|' '\n' | sed -e 's/^/--allow-group=/')
"${SDK_SCRIPTS}/build_library/gen_tmpfiles.py" --root="${root_fs_dir}" \
    --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_var.conf" \
    "${ignores[@]}" "${allowed_users[@]}" "${allowed_groups[@]}" "${root_fs_dir}/var"

# Second pass records the remaining dirs, now also ignoring base_image_var.conf's.
mapfile -t ignores < <(awk '/^[dDfFL]/ {print "--ignore=" $2}' \
                           "${root_fs_dir}"/usr/lib/tmpfiles.d/*.conf)
"${SDK_SCRIPTS}/build_library/gen_tmpfiles.py" --root="${root_fs_dir}" \
    --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_var_late.conf" \
    "${ignores[@]}" "${allowed_users[@]}" "${allowed_groups[@]}" "${root_fs_dir}/var"

cat > "${root_fs_dir}/boot/flatcar/first_boot" <<EOF
If this file exists, Ignition will run and then delete the file.
EOF

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

# Set /etc/{g,}shadow group to the shadow group so unix_chkpwd/chage/expiry work.
# Belongs in an ebuild, but baselayout installs these and we don't want more deps.
chgrp \
    --reference="${root_fs_dir}/usr/bin/chage" \
    "${root_fs_dir}"/{etc,usr/share/baselayout}/{g,}shadow

if [[ $(find "${root_fs_dir}/usr/share/flatcar/etc" -size +0 ! -type d 2>/dev/null | wc -l) -gt 0 ]]; then
  die "Unexpected non-empty files in ${root_fs_dir}/usr/share/flatcar/etc"
fi
# Backwards-compat symlinks still target this folder, so we can't drop it.
rm -rf "${root_fs_dir}/usr/share/flatcar/etc"
cp -a "${root_fs_dir}/etc" "${root_fs_dir}/usr/share/flatcar/etc"
# Default confext, verity-signed: verity lets the refresh identify this image and
# skip re-setup on final boot (saves a daemon-reload and avoids /etc briefly
# vanishing before systemd-sysext's atomic remount). Build as a folder, then DDI.
rm -rf "${root_fs_dir}/usr/lib/confexts/00-flatcar-default"
mkdir -p "${root_fs_dir}/usr/lib/confexts/00-flatcar-default"
# Do a copy because we keep /etc for the flatcar (.tar) container and the developer container
cp -a "${root_fs_dir}/etc" "${root_fs_dir}/usr/lib/confexts/00-flatcar-default/etc"
mkdir -p "${root_fs_dir}/usr/lib/confexts/00-flatcar-default/etc/extension-release.d/"
echo ID=_any | tee "${root_fs_dir}/usr/lib/confexts/00-flatcar-default/etc/extension-release.d/extension-release.00-flatcar-default" > /dev/null

# mkfs.erofs (spawned by --make-ddi) needs libgcc_s/libstdc++; the base
# sub-image's postinst ran ldconfig for that.
#
# Signed with the same key as the sysexts (VerityKey=/VerityCertificate= in
# mkosi.conf), mirroring build_library/build_image_util.sh finish_image():733-738
# where confext and sysexts share ${SYSEXT_SIGNING_KEY_DIR}/sysexts.{key,crt}.
# The trust anchor is installed by mkosi itself (configure_verity_certificate()
# copies VerityCertificate= to /usr/lib/verity.d), so the image carries exactly
# one anchor and the build stays reproducible.
systemd-repart \
  --make-ddi=confext \
  --private-key="${SRCDIR}/mkosi.key" \
  --certificate="${SRCDIR}/mkosi.crt" \
  --copy-source="${root_fs_dir}/usr/lib/confexts/00-flatcar-default" \
  "${root_fs_dir}/usr/lib/confexts/00-flatcar-default.raw"
rm -rf "${root_fs_dir}/usr/lib/confexts/00-flatcar-default"

# Ship an empty /var but keep /var/db + /var/cache/edb; the top-level
# mkosi.finalize drops them.
find "${root_fs_dir}/var" -mindepth 1 \
    -path "${root_fs_dir}/var/db" -prune -o \
    -path "${root_fs_dir}/var/cache/edb" -prune -o \
    \( -type f -o -type l \) -print -delete >/dev/null 2>&1 || true

for folder in "${root_fs_dir}/"*; do
  case "${folder#${root_fs_dir}}" in
    # /efi and /oem-tree: mkosi.postinst staged the ESP and OEM contents there.
    /boot|/usr|/oem|/var|/dev|/proc|/efi|/oem-tree)
      # keep
      :
      ;;
    *)
      rm --one-file-system -rf "${folder}" || echo FAILED
      ;;
  esac
done
