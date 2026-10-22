#!/usr/bin/env bash
# Compare the sysexts mkosi built against upstream's (build_image) for the same
# Flatcar version: extension-release, file tree (path, type, mode, owner, size,
# sha256, link target) and the signing key of every kernel module.
#
# Run as root inside the SDK container (needs systemd-dissect, loop devices):
#
#   tools/compare-upstream-sysexts.sh [-o OUTPUT_DIR] [-u UPSTREAM] [-w WORKDIR] [NAME...]
#
#   -o  mkosi output dir (default: mkosi.output next to this script's tree)
#   -u  upstream images: a bincache URL or a local build_image output dir
#       (default: https://bincache.flatcar-linux.net/images/<arch>/<VERSION>)
#   -w  work dir for downloads and reports (default: /var/tmp/compare-sysexts)
#   NAME  sysext names, e.g. flatcar-zfs docker-flatcar (default: every
#       mkosi.output/*.raw except image.raw)
#
# Built-in sysexts (containerd-flatcar, docker-flatcar) live in upstream's
# rootfs-included-sysexts/; everything else sits next to the image.
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "$0")/.." && pwd)"
outdir="${here}/mkosi.output"
upstream=""
workdir="/var/tmp/compare-sysexts"

while getopts "o:u:w:h" opt; do
  case "${opt}" in
    o) outdir="${OPTARG}" ;;
    u) upstream="${OPTARG}" ;;
    w) workdir="${OPTARG}" ;;
    *) sed -n '2,19p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

[[ ${EUID} -eq 0 ]] || { echo "run as root (systemd-dissect needs loop devices)" >&2; exit 1; }

osrel="${outdir}/base/usr/lib/os-release"
[[ -r "${osrel}" ]] || { echo "${osrel} not found; build first or pass -o" >&2; exit 1; }
version="$(. "${osrel}"; echo "${VERSION}")"
board="$(. "${osrel}"; echo "${FLATCAR_BOARD:-amd64-usr}")"
arch="${board%-usr}"
upstream="${upstream:-https://bincache.flatcar-linux.net/images/${arch}/${version}}"

if [[ $# -eq 0 ]]; then
  mapfile -t names < <(cd "${outdir}" && ls -1 ./*.raw | sed 's#^\./##; s#\.raw$##' | grep -vx image | sort)
else
  names=("$@")
fi

mkdir -p "${workdir}"
echo "mkosi:    ${outdir}"
echo "upstream: ${upstream}"
echo "version:  ${version} (${arch})"
echo

upstream_path() {
  case "$1" in
    containerd-flatcar|docker-flatcar) echo "rootfs-included-sysexts/$1.raw" ;;
    *) echo "$1.raw" ;;
  esac
}

# Fetch (or link) upstream's raw into the work dir; prints its path.
fetch_upstream() {
  local name="$1" rel dst
  rel="$(upstream_path "${name}")"
  dst="${workdir}/upstream/${rel}"
  mkdir -p "$(dirname "${dst}")"
  if [[ "${upstream}" == http* ]]; then
    [[ -s "${dst}" ]] || curl -fsSL -o "${dst}" "${upstream}/${rel}" || { rm -f "${dst}"; return 1; }
  else
    [[ -s "${upstream}/${rel}" ]] || return 1
    ln -sf "${upstream}/${rel}" "${dst}"
  fi
  echo "${dst}"
}

extrel() {  # normalised extension-release: unquoted, sorted
  systemd-dissect --copy-from "$1" "/usr/lib/extension-release.d/extension-release.$2" - 2>/dev/null \
    | sed -E "s/^([A-Z_]+)=['\"]?([^'\"]*)['\"]?$/\1=\2/" | sort
}

mtree() {
  systemd-dissect --mtree "$1" 2>/dev/null | sed -E 's/ time=[^ ]*//' | sort
}

# Serial of each module's signing cert: "<path> <serial|UNSIGNED>".
ko_signers() {  # $1 = mounted tree
  local ko
  while IFS= read -r ko; do
    case "${ko}" in
      *.xz)  xz -dc "${ko}" ;;
      *.zst) zstd -dcq "${ko}" ;;
      *)     cat "${ko}" ;;
    esac | python3 -c '
import struct, subprocess, sys
d = sys.stdin.buffer.read(); m = b"~Module signature appended~\n"
if not d.endswith(m): print("UNSIGNED"); sys.exit()
n = struct.unpack(">I", d[-len(m)-4:-len(m)])[0]
o = subprocess.run(["openssl", "cms", "-cmsout", "-print", "-inform", "DER"],
                   input=d[-len(m)-12-n:-len(m)-12], capture_output=True).stdout.decode()
print(next((l.split()[-1] for l in o.splitlines() if "serialNumber:" in l), "UNKNOWN"))
' | sed "s#^#${ko#"$1"} #"
  done < <(find "$1" -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' | sort)
}

dissect_signers() {  # $1 = raw
  local mp
  mp="$(mktemp -d)"
  systemd-dissect --read-only --mount "$1" "${mp}" >/dev/null 2>&1 || { rmdir "${mp}"; return 0; }
  ko_signers "${mp}"
  systemd-dissect --umount "${mp}" >/dev/null 2>&1 || true
  rmdir "${mp}"
}

# The signer the image's own kernel modules use; sysext modules must match it.
base_signer="$(ko_signers "${outdir}/base" | awk '{print $2}' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
echo "base kernel module signer: ${base_signer:-none found}"
echo

summary=()
for name in "${names[@]}"; do
  mk="${outdir}/${name}.raw"
  r="${workdir}/${name}"
  rm -rf "${r}"; mkdir -p "${r}"
  echo "################ ${name}"
  if [[ ! -s "${mk}" ]]; then
    echo "  no ${mk}"; summary+=("${name}: not built"); echo; continue
  fi
  if ! up="$(fetch_upstream "${name}")"; then
    echo "  no upstream $(upstream_path "${name}")"; summary+=("${name}: no upstream"); echo; continue
  fi

  printf '  size: upstream %s, mkosi %s\n' "$(stat -Lc %s "${up}")" "$(stat -Lc %s "${mk}")"

  extrel "${up}" "${name}" > "${r}/up.extrel"
  extrel "${mk}" "${name}" > "${r}/mk.extrel"
  mtree "${up}" > "${r}/up.mtree"
  mtree "${mk}" > "${r}/mk.mtree"
  dissect_signers "${up}" > "${r}/up.signers"
  dissect_signers "${mk}" > "${r}/mk.signers"

  echo "  extension-release (< upstream, > mkosi):"
  if diff -q "${r}/up.extrel" "${r}/mk.extrel" >/dev/null; then
    echo "    identical"
  else
    diff "${r}/up.extrel" "${r}/mk.extrel" | grep '^[<>]' | sed 's/^/    /'  || true
  fi

  # Paths only on one side, then same path with different attributes; the
  # extension-release file itself is covered above.
  cut -d' ' -f1 "${r}/up.mtree" | sort > "${r}/up.paths"
  cut -d' ' -f1 "${r}/mk.mtree" | sort > "${r}/mk.paths"
  comm -23 "${r}/up.paths" "${r}/mk.paths" > "${r}/only-upstream"
  comm -13 "${r}/up.paths" "${r}/mk.paths" > "${r}/only-mkosi"
  join -t $'\t' -j1 <(sed 's/ /\t/' "${r}/up.mtree" | sort -t $'\t' -k1,1) \
                    <(sed 's/ /\t/' "${r}/mk.mtree" | sort -t $'\t' -k1,1) \
    | awk -F'\t' '$2 != $3 && $1 !~ /extension-release\.d/ {print $1}' > "${r}/differ"
  for kind in only-upstream only-mkosi differ; do
    n=$(wc -l < "${r}/${kind}")
    echo "  ${kind}: ${n}"
    head -20 "${r}/${kind}" | sed 's/^/    /'
    if [[ ${n} -gt 20 ]]; then echo "    ... (${r}/${kind})"; fi
  done

  echo "  kernel modules (path signer):"
  if [[ -s "${r}/mk.signers" || -s "${r}/up.signers" ]]; then
    sed 's/^/    mkosi    /' "${r}/mk.signers"
    sed 's/^/    upstream /' "${r}/up.signers"
    bad=$(awk -v s="${base_signer}" '$2 != s' "${r}/mk.signers" | wc -l)
    if [[ ${bad} -ne 0 ]]; then echo "    !! ${bad} mkosi module(s) not signed by the base kernel's key"; fi
  else
    echo "    none"
  fi

  n_files=$(( $(wc -l < "${r}/only-upstream") + $(wc -l < "${r}/only-mkosi") + $(wc -l < "${r}/differ") ))
  if [[ ${n_files} -eq 0 ]]; then
    summary+=("${name}: files identical")
  else
    summary+=("${name}: ${n_files} file difference(s)")
  fi
  echo
done

echo "################ summary (reports in ${workdir}/<name>/)"
printf '  %s\n' "${summary[@]}"
