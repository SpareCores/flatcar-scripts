#!/usr/bin/env bash
. "${SRCDIR}/lib/postinst.sh"

# Generate /usr/share/licenses/licenses.json.bz2 in the verity'd /usr so it is
# always present even when a test masks the docker/containerd sysexts. Upstream
# ships this manifest; kola sysext.custom-docker.sysext reads the Docker version
# from it. Covers base + the built-in sysexts, whose pkgdbs tools/save-pkgdb.sh
# saved.
"${SRCDIR}/tools/write-licenses.sh" "${builtin_sysexts[@]}"
