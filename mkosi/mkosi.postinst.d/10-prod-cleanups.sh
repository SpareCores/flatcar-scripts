#!/usr/bin/env bash
# create_prod_image()'s clean-ups after the sysext snapshot, the same order as
# upstream.
. "${SRCDIR}/lib/postinst.sh"

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
