#!/usr/bin/env bash
# Leave only the mount points and staging trees the partitions are built from.
. "${SRCDIR}/lib/postinst.sh"

# Ship an empty /var but keep /var/db + /var/cache/edb; the top-level
# mkosi.finalize drops them.
find "${root_fs_dir}/var" -mindepth 1 \
    -path "${root_fs_dir}/var/db" -prune -o \
    -path "${root_fs_dir}/var/cache/edb" -prune -o \
    \( -type f -o -type l \) -print -delete >/dev/null 2>&1 || true

for folder in "${root_fs_dir}/"*; do
  case "${folder#${root_fs_dir}}" in
    # /efi: 05-esp.sh staged the ESP there.
    /boot|/usr|/oem|/var|/dev|/proc|/efi)
      # keep
      :
      ;;
    *)
      rm --one-file-system -rf "${folder}" || echo FAILED
      ;;
  esac
done
