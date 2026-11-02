#!/bin/bash
# Make the next mkosi build compile the kernel and every kernel-module package
# from source: unmerge them from the board root and drop their binpkgs.
#
# Kernel-module packages are those whose ebuild inherits coreos-kernel,
# linux-mod or linux-mod-r1 and that are installed in the board root or have a
# binpkg in PKGDIR (coreos-kernel, coreos-modules, zfs, nvidia-drivers, ...).
#
# Run inside the SDK, then build with:
#   mkosi --environment=FLATCAR_SOURCE_BUILD=1 \
#         --environment=FLATCAR_ALLOW_REMOTE_BINPKGS=0 build -ff
set -euo pipefail

board="amd64-usr"
dry_run=0
usage() { echo "usage: $0 [--board=amd64-usr|arm64-usr] [--dry-run]" >&2; exit 2; }
for arg; do
    case "${arg}" in
        --board=*) board="${arg#*=}" ;;
        --dry-run) dry_run=1 ;;
        *) usage ;;
    esac
done

root="/build/${board}"
pkgdir="$(PORTAGE_CONFIGROOT="${root}" portageq envvar PKGDIR)"
repos=(/mnt/host/source/src/third_party/{coreos-overlay,portage-stable})
run() { echo "+ $*"; [[ ${dry_run} -eq 1 ]] || "$@"; }

mapfile -t kmod_pkgs < <(
    for repo in "${repos[@]}"; do
        grep -lE '^inherit .*\b(coreos-kernel|linux-mod|linux-mod-r1)\b' "${repo}"/*/*/*.ebuild
    done 2>/dev/null |
    awk -F/ '{print $(NF-2) "/" $(NF-1)}' | sort -u
)

installed=() binpkgs=()
for cp in "${kmod_pkgs[@]}"; do
    vdb=("${root}/var/db/pkg/${cp%/*}/${cp#*/}"-[0-9]*)
    if [[ -d "${vdb[0]}" ]]; then
        # Inherits a module eclass but builds no modules with our USE (ipset, hv-daemons).
        grep -qs ' /usr/lib/modules/' "${vdb[@]/%//CONTENTS}" || continue
        installed+=("${cp}")
    fi
    # Both binpkg layouts: cat/pn-ver.tbz2 and cat/pn/pn-ver-N.{xpak,gpkg.tar}.
    for f in "${pkgdir}/${cp}"-[0-9]*.tbz2 "${pkgdir}/${cp}"/*; do
        [[ -e "${f}" ]] && binpkgs+=("${f}")
    done
done
mapfile -t installed < <(printf '%s\n' "${installed[@]}" | sort -u | sed '/^$/d')

echo "kernel-module packages in the tree: ${#kmod_pkgs[@]}"
echo "installed in ${root}: ${installed[*]:-none}"
echo "binpkgs in ${pkgdir}: ${#binpkgs[@]}"
printf '  %s\n' "${binpkgs[@]#"${pkgdir}/"}"

if [[ ${#installed[@]} -gt 0 ]]; then
    run sudo "emerge-${board}" --unmerge "${installed[@]}"
fi

# Unmerge keeps files modified since install; drop module trees nobody owns
# anymore so the rebuilt packages don't merge over stale leftovers.
for kdir in "${root}"/usr/lib/modules/*; do
    [[ -d "${kdir}" ]] || continue
    if ! grep -qsF " ${kdir#"${root}"}/" "${root}"/var/db/pkg/*/*/CONTENTS; then
        run sudo rm -rf "${kdir}"
    fi
done

if [[ ${#binpkgs[@]} -gt 0 ]]; then
    run sudo rm -rf "${binpkgs[@]}"
    run sudo env PORTAGE_CONFIGROOT="${root}" ROOT="${root}" emaint binhost --fix
fi
