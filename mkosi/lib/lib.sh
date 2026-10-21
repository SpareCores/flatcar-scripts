#!/bin/bash
# Sourced, not executed: remember the caller's shell options and put them back
# at the end of this file. The strict mode below is for our own sourcing of the
# SDK libraries; hooks must stay free to run without it. In particular -u has to
# be off when calling upstream build_library functions -- write_licenses()
# declares `local pkg pkg_sep` and then tests $pkg_sep before assigning it
# (build_image_util.sh:322,337), which is an unbound-variable error under -u.
#
# $- is read in this shell, not a subshell: bash turns errexit off inside
# command substitution, so "$(set +o)" would report -e as unset and lose it.
__libsh_caller_opts="$-"
__libsh_caller_pipefail="$(shopt -po pipefail)"
set -euo pipefail

# mkosi exports ARCHITECTURE (its own naming: x86-64 / arm64). Flatcar boards are
# <arch>-usr with portage's arch spelling.
sdk_board() {
  local arch="${ARCHITECTURE:?ARCHITECTURE must be set by mkosi}"
  case "${arch}" in
    x86-64|x86_64|amd64) echo "amd64-usr" ;;
    arm64|aarch64)       echo "arm64-usr" ;;
    *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;;
  esac
}

export SDK_SCRIPTS="/mnt/host/source/src/scripts"

# BuildSources= mounts the board sysroot at /work/src/build (mkosi re-roots
# every target under /work/src). The cross toolchain's --sysroot, make.conf and
# the setup_board wrappers all hardcode /build, so restore that path.
#
# A bind mount, not a symlink: the board's make.profile is a RELATIVE symlink
# (../../../../mnt/host/source/...) and `..` is resolved against the real tree,
# so under /work/src/build it escapes to /work/src/mnt/... and portage reports
# "profile is not a symlink". A bind puts the tree at depth 1 where the symlink
# was written to work. Each script type gets a fresh sandbox, hence doing it
# here rather than in a hook.
if [[ ! -e /build ]]; then
  mkdir -p /build
  mount --bind /work/src/build /build
fi

# The kernel config hardcodes MODULE_SIG_KEY at the SDK's key path, so the
# BuildSources= mount has to appear there too.
if [[ -n "${MODULE_SIGNING_KEY_DIR:-}" && -d /work/src/module-signing-keys ]] \
    && ! mountpoint -q "${MODULE_SIGNING_KEY_DIR}"; then
  mkdir -p "${MODULE_SIGNING_KEY_DIR}"
  mount --bind /work/src/module-signing-keys "${MODULE_SIGNING_KEY_DIR}"
fi

# mkosi writes its own /etc/nsswitch.conf without the SDK's `usrfiles` module,
# so acct-user/acct-group entries (they live in /usr/share/baselayout/passwd)
# become invisible and every doins -o <user> / fowners in a source build fails.
if ! grep -q usrfiles /etc/nsswitch.conf 2>/dev/null; then
  mount --bind /usr/share/baselayout/nsswitch.conf /etc/nsswitch.conf
fi

export PATH="${PATH}:/usr/local/sbin/"
export BUILD_LIBRARY_DIR="${SDK_SCRIPTS}/build_library"
export BOARD="$(sdk_board)"
export BOARD_ROOT="/build/${BOARD}"
export FLAGS_version="$IMAGE_VERSION"
export FLAGS_output_root="${ARTIFACTDIR?ARTIFACTDIR must be set by mkosi}/"
export FLAGS_board="${BOARD}"
export FLAGS_group="$FLATCAR_UPDATE_GROUP"
# NOT exported, matching upstream (build_image_util.sh:19, common.sh:439):
# BUILD_DIR is a reserved ebuild variable (multibuild/multilib-minimal set it
# per-ABI and mkdir it). Exporting ours leaks it into the ebuild environment,
# where it wins and the phase dies trying to mkdir an SDK path as uid 250.
BUILD_DIR="${FLAGS_output_root}/${BOARD}/${FLAGS_group}-${FLAGS_version}"

NUM_JOBS=0
GCLIENT_ROOT=''
COMMON_SH=''
set +u
. "${SDK_SCRIPTS}/common.sh"
set -u
# Source order mirrors build_image:108-114. toolchain_util.sh has to come before
# build_image_util.sh: the latter sources sbsign_util.sh, which calls
# get_sdk_libdir() at load time, and that function lives in toolchain_util.sh.
. "${SDK_SCRIPTS}/build_library/toolchain_util.sh" # for get_board_arch, get_sdk_libdir
. "${SDK_SCRIPTS}/build_library/board_options.sh" # for pkg_version
. "${SDK_SCRIPTS}/build_library/build_image_util.sh"
. "${SDK_SCRIPTS}/build_library/prod_image_util.sh"
. "${SDK_SCRIPTS}/build_library/vm_image_util.sh" # for _write_qemu_uefi_conf

# After the sources, not before: board_options.sh and the files that source it
# reassign DISTDIR from make.conf, whose path is a host path that is not bound
# into the sandbox. Same rule as BOARD/BUILD_DIR -- exports placed above the
# `.` lines are advisory.
export DISTDIR="/work/src/distfiles"

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

die() {
  echo "ERROR: $*" >&2
  exit 1
}

create_configroot() {
  update_group="$1"
  # based on start_image

 # First thing first, install baselayout to create a working filesystem.
  mkosi-install --nodeps --oneshot --update sys-apps/baselayout

  # FIXME(marineam): Work around glibc setting EROOT=$ROOT
  # https://bugs.gentoo.org/show_bug.cgi?id=473728#c12
  sudo mkdir -p "${BUILDROOT}/etc/ld.so.conf.d"

  # echo "FLAGS_group before unsetting '$FLAGS_group'"
  # unset FLAGS_group
  # Set /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
    --root="${BUILDROOT}" \
    --group="${update_group}" \
    --board="${BOARD}"

  mkdir -p "${BUILD_DIR}"/configroot/etc/portage/profile
  ln -sfn "${BOARD_ROOT}"/etc/portage/make.* \
      "${BOARD_ROOT}"/etc/portage/package.* \
      "${BOARD_ROOT}"/etc/portage/repos.conf \
      "${BUILD_DIR}"/configroot/etc/portage/
}

# sdk_call() {
#   local file=$1 func=$2; shift 2
#   (
#    set -e
#    setup_env
#     # . "${SDK_SCRIPTS}/common.sh" >/dev/null 2>&1 || true
#    . "${SDK_SCRIPTS}/$file"
#    declare -F "$func" >/dev/null || die "sdk_call: no function '$func' in $file"
#    "$func" "$@"
#   )
# }


# Install into $BUILDROOT from the board's binpkgs (pass 2; emerge_from_source
# is pass 1). --root overrides the emerge-<board> wrapper's ROOT=$BOARD_ROOT so
# packages land in the image instead of the sysroot.
#
# We disable portage's sandbox (-sandbox -usersandbox and the namespace ones).
# mkosi already runs hooks inside a bwrap sandbox.
sdk_emerge() {
    local board configroot
    # TODO: reuse from setup_env
    # BUILD_DIR="${ARTIFACTDIR}/$(sdk_board)/${FLATCAR_UPDATE_GROUP}-${IMAGE_VERSION}"

    board="$(sdk_board)"
    root="${BUILDROOT:?BUILDROOT must be set by mkosi}"
    configroot="${BUILD_DIR}/configroot/"

    # Drop mkosi's /scripts shims from PATH (see sdk_clean_path).
    local clean_path
    clean_path="$(sdk_clean_path)"

    "${SDK_ENV_SCRUB[@]}" \
    ROOT="${BUILDROOT}" \
    PORTAGE_CONFIGROOT="${configroot}" \
    PATH="${clean_path}" \
    FEATURES="-ebuild-locks -merge-wait -sandbox -usersandbox -network-sandbox -pid-sandbox -ipc-sandbox" \
        "emerge-${board}" --root="${BUILDROOT}" "$@"

    # Make sure profile.env has been generated
    sudo -E ROOT="${BUILDROOT}" env-update --no-ldconfig
}

# Drop mkosi's /scripts shims from PATH: mkosi installs shims there that wrap
# groupadd and useradd as `groupadd --root /buildroot "$@"`, while
# acct-group.eclass/acct-user.eclass already pass --prefix "${ROOT}".
sdk_clean_path() {
  printf '%s' "${PATH}" | tr ':' '\n' | grep -vx '/scripts' | paste -sd: -
}

# mkosi's script variables collide with build-system conventions in ebuild
# phases (SRCDIR=/work/src breaks vim's configure). BUILDROOT stays: hooks use it.
SDK_ENV_SCRUB=(env -u SRCDIR -u CHROOT_SRCDIR -u DESTDIR -u CHROOT_DESTDIR
               -u PACKAGEDIR -u ARTIFACTDIR)

# Goo to attempt to resolve dependency loops on individual packages.
# If this becomes insufficient we will need to move to a full multi-stage
# bootstrap process like we do with the SDK via catalyst.
#
# Called like:
#
#     break_dep_loop [PKG_USE_PAIR]…
#
# PKG_USE_PAIR consists of two arguments: a package name (for example:
# sys-fs/lvm2), and a comma-separated list of USE flags to clear (for
# example: udev,systemd).
break_dep_loop() {
  local -a pkgs
  local -a all_flags
  local -a args
  local flag_file="${BOARD_ROOT}/etc/portage/package.use/break_dep_loop"
  local -a flag_file_entries
  local -a pkg_summaries

  # Be sure to clean up use flag hackery from previous failed runs
  rm -f "${flag_file}"

  if [[ $# -eq 0 ]]; then
      return 0
  fi

  # Temporarily compile/install packages with flags disabled. If a binary
  # package is available use it regardless of its version or use flags.
  local pkg
  local -a flags
  local disabled_flags
  while [[ $# -gt 0 ]]; do
    pkg="${1}"
    pkgs+=("${pkg}")
    flags=( ${2//,/ } )
    all_flags+=("${flags[@]}")
    disabled_flags="${flags[@]/#/-}"
    flag_file_entries+=("${pkg} ${disabled_flags}")
    args+=("--buildpkg-exclude=${pkg}")
    pkg_summaries+=("${pkg}[${disabled_flags}]")
    shift 2
  done

  # If packages are already installed we have nothing to do
  local any_package_uninstalled=0
  for pkg in "${pkgs[@]}"; do
    if ! portageq-"${BOARD}" has_version "${BOARD_ROOT}" "${pkgs[@]}"; then
      any_package_uninstalled=1
      break
    fi
  done
  if [[ ${any_package_uninstalled} -eq 0 ]]; then
    return 0
  fi

  # Likewise, nothing to do if the flags aren't actually enabled.
  local any_flag_enabled=0
  for pkg in "${pkgs[@]}"; do
    if pkg_use_enabled "${pkg}" "${all_flags[@]}"; then
      any_flag_enabled=1
      break
    fi
  done
  if [[ ${any_flag_enabled} -eq 0 ]]; then
    return 0
  fi

  info "Merging ${pkg_summaries[@]}"
  mkdir -p "${flag_file%/*}"
  "${flag_file}" <<<"${flag_file_entries[0]}"
  local entry
  for entry in "${flag_file_entries[@]:1}"; do
    echo "${entry}" >> "${flag_file}"
  done
  # rebuild-if-unbuilt is disabled to prevent portage from needlessly
  # rebuilding zlib for some unknown reason, in turn triggering more rebuilds.
  "${EMERGE_CMD[@]}" "${EMERGE_FLAGS[@]}" \
    --rebuild-if-unbuilt=n \
    "${args[@]}" "${pkgs[@]}"
  rm -f "${flag_file}"
}

# Build packages from source, caching the result as binpkgs in PKGDIR. This is
# pass 1 of Flatcar's two-pass model; sdk_emerge then installs those binpkgs
# into the image with --usepkgonly, so compilers and DEPENDs never reach the
# rootfs.
#
# Board-rooted, like build_packages: the emerge-<board> wrapper's
# ROOT=SYSROOT=/build/<board> is what lets portage resolve build deps while
# cross-compiling. Rooting the graph at the image instead spans both roots
# (DEPENDs still land in the sysroot) and turns every build into a board
# upgrade -- slot conflicts between the board snapshot and the current overlay,
# up to scheduling a kernel compile. Tried twice, including against a freshly
# resynced board; upgrading the board is build_packages' job, not this one's.
#
# Flags are build_packages:123-155 minus --update --deep --newuse --backtrack
# --select: those exist to bring the whole board up to date, while this only
# has to make the image's atoms available. --buildpkg is likewise absent, the
# board's FEATURES already carries buildpkg/buildpkg-live/buildpkg-proactive.
#
# Consequence: an atom that is installed in the sysroot but whose binpkg was
# deleted looks satisfied here and pass 2 then fails with "no binary packages
# to satisfy" -- regenerate it with quickpkg, or unmerge before deleting.
# Likewise an edited ebuild needs an -rN bump to be rebuilt; portage does not
# rebuild on ebuild content alone.
emerge_from_source() {
    local board
    board="$(sdk_board)"

    # FLATCAR_ALLOW_REMOTE_BINPKGS=1 lets portage pull a matching binpkg from
    # the board's PORTAGE_BINHOST instead of compiling (the local PKGDIR is
    # always used, --usepkg below). Set it to 0 when iterating on an ebuild
    # WITHOUT bumping -rN: binpkgs match on CPV+USE+deps, not on ebuild
    # content, so a remote package for the same version satisfies the dep and
    # the local edit is silently dropped.
    local binpkg_args=()
    if [ "${FLATCAR_ALLOW_REMOTE_BINPKGS:-1}" = 1 ]; then
        binpkg_args=(--getbinpkg)
    fi

    # echo "Breaking deploop"
    # break_dep_loop sys-apps/util-linux cryptsetup,pam,systemd,udev \
    #                sys-fs/cryptsetup udev \
    #                sys-fs/lvm2 systemd,udev \
    #                sys-apps/systemd audit,cryptsetup,pam,selinux,tpm \
    #                net-misc/curl http2 \
    #                net-libs/nghttp2 systemd \
    #                sys-libs/pam audit,systemd \
    #                sys-auth/pambase sssd,systemd
    # echo DONE

    # build_packages:141 -- pin the toolchain to existing binpkgs so a source
    # build never drags gcc/binutils/glibc rebuilds in behind it.
    local binonly_args
    read -r -a binonly_args <<<"$(get_binonly_args)"

    # DISTDIR is passed explicitly rather than relied on from the environment:
    # the wrapper's `exec sudo -E emerge` would carry the export, but naming it
    # here keeps the sandbox-only path visible at the call site. make.conf's
    # value is a host path that is not bound into the sandbox.
    "${SDK_ENV_SCRUB[@]}" \
    DISTDIR="${DISTDIR}" \
    PATH="$(sdk_clean_path)" \
    FEATURES="-ebuild-locks -merge-wait -sandbox -usersandbox -network-sandbox -pid-sandbox -ipc-sandbox" \
        "emerge-${board}" \
        "--update" \
        "--deep" \
        "--newuse" \
        "--verbose" \
        "--backtrack=30" \
        "--select" \
        "--usepkg" \
        "--with-bdeps=n" \
        "${binonly_args[@]}" \
        "${binpkg_args[@]}" \
        "--getbinpkg" \
        "--jobs=22" \
        "$@"

        # --usepkg \
        # --with-bdeps y \
        # "${binonly_args[@]}" \
        # "${binpkg_args[@]}" \
        # --jobs="${NUM_JOBS}" \
        # --verbose \
}

eval "${__libsh_caller_pipefail}"
set +eu
if [[ ${__libsh_caller_opts} == *e* ]]; then set -e; fi
if [[ ${__libsh_caller_opts} == *u* ]]; then set -u; fi
unset __libsh_caller_opts __libsh_caller_pipefail
