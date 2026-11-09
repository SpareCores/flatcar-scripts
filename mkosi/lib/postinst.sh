# Sourced by every mkosi.postinst.d/ phase. mkosi runs them in name order,
# all before mkosi.finalize builds and seals the verity'd /usr, so anything that
# has to be covered by the hash belongs in a phase.
set -euo pipefail

[[ "${MKOSI_DEBUG:-0}" == "1" ]] && set -x

# shellcheck source=lib/lib.sh
. "${SRCDIR}/lib/lib.sh"

root_fs_dir="${BUILDROOT:?BUILDROOT must be set by mkosi}"
