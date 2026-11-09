#!/usr/bin/env bash
# Tmpfiles rules that recreate /var at boot, and the first-boot flag.
. "${SRCDIR}/lib/postinst.sh"

# Generate tmpfiles rules that recreate the /var skeleton at boot. Ignore paths
# already covered by existing tmpfiles configs; the first pass also skips dirs
# owned by users flatcar-tmpfiles does not copy, the second records the rest.
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
    "${ignores[@]}" "${root_fs_dir}/var"

cat > "${root_fs_dir}/boot/flatcar/first_boot" <<EOF
If this file exists, Ignition will run and then delete the file.
EOF
