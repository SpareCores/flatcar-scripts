# Flatcar mkosi build — runs inside the SDK container

Builds Flatcar disk images with **stock upstream mkosi** (no fork). All
Flatcar-specific work happens in script hooks that call the SDK's own tooling:
packages are installed by the board `emerge` from the board sysroot at
`/build/<board>`, not downloaded from a bincache.

## Run it

From inside the SDK container, in this directory:

    mkosi build                       # amd64 (default)
    mkosi -a arm64 build              # arm64
    mkosi --profile oem-qemu build    # add the OEM partition

i.e. from the host: `./run_sdk_container … sudo mkosi build`.

There is no wrapper script — `mkosi.conf` is the interface.

## How packages get installed

`Distribution=custom` is a **no-op backend**: `setup()`/`install()` are `pass`
and `package_manager()` returns the base no-op `PackageManager` whose
`scripts()` returns `{}`.

Two consequences, and we use both:

1. **`Packages=` is parsed but inert.** mkosi never installs it
   (`install_distribution()` → the no-op `.install()`). It *does* survive into
   the script config JSON, so `tools/prepare.sh` reads it back and drives the
   install itself. `Packages=` stays the declarative source of truth you edit.

2. **The `mkosi-*` helper names are unclaimed.** mkosi assembles the hook PATH as
   `{"mkosi-chroot": …} | package_manager().scripts(context)` and binds it at
   `/scripts`. Since `custom` contributes nothing, `ExtraSearchPaths=%D/tools/bin`
   can supply our own `mkosi-install` / `-remove` / `-upgrade` / `-reinstall`.

So the flow per sub-image is:

    mkosi.conf: Packages=…  ->  tools/prepare.sh (readback)  ->  mkosi-install  ->  emerge

`tools/bin/lib.sh` maps mkosi's `ARCHITECTURE` (`x86-64`/`arm64`) to the Flatcar
board (`amd64-usr`/`arm64-usr`), then prefers the SDK's `emerge-<board>` wrapper
and falls back to plain `emerge` with explicit `--config-root`/`--sysroot`
(the same invocation `build_sysext` uses).

## Layout

    mkosi.conf                  top-level disk; Distribution=custom, ExtraSearchPaths
    tools/prepare.sh            shared hook: Packages=/RemovePackages= readback
    tools/bin/mkosi-*           package-manager helpers -> SDK emerge
    tools/bin/lib.sh            board mapping + emerge invocation
    mkosi.images/base/          the OS tree (coreos-base/coreos)
    mkosi.images/*-sysext/      built-in sysexts (containerd, docker) + oem-qemu
    mkosi.images/{grub,gcc-runtime}/   build-tooling overlays, nothing ships
    mkosi.profiles/oem-qemu/    vendors the OEM sysext into the OEM partition
    mkosi.repart/               partition layout (verity /usr, ESP, ROOT, OEM)

Every sub-image that installs packages sets `PrepareScripts=%D/tools/prepare.sh`
explicitly — it is shared, so it cannot be auto-discovered as `mkosi.prepare`.

## Debugging the hooks

`mkosi box` opens a shell in the same sandbox environment the other verbs use,
so the `ExtraSearchPaths=` binds (board sysroot, overlays, `/var/db/pkg`,
`.repo`) are all visible:

    sudo mkosi box                    # or: sudo mkosi box -- portageq envvar -v 'BRANDING_OS_*'

Use it to check paths, `portageq`, and `emerge` invocations in seconds instead of
running a full build.

**But `box` is not the prepare-script sandbox.** It has no `$BUILDROOT`,
no `$MKOSI_CONFIG` and no `/scripts` (where mkosi installs its `groupadd` /
`useradd` shims) — those exist only while a build runs a hook. For anything
involving those, point `PrepareScripts=` at a throwaway diagnostic script
instead. Set `Packages=` empty at the same time so the diagnostic runs without
re-merging the whole package set.

## Gotchas

- **Never `docker rm` the SDK container after running `build_packages`.**
  `/build/<board>` is **not** a bind mount — it lives in the container's
  writable layer. Only `sdk_container/`, `__build__/images` and the scripts tree
  are mounted from the host. Removing the container throws away the board
  sysroot and every binary package `build_packages` produced (hours of work),
  and `setup_board` then silently recreates a bare ~122-package board.
  Container flags (`-m`, `--security-opt`, …) only apply at *create* time, so
  decide on them **before** building packages.

- **`cp: setting attributes ... Operation not supported` during "Syncing package
  manager metadata" / "Copying repository metadata".** mkosi persists its keyring
  and metadata caches with `cp --preserve=…,xattr`, and the container path cannot
  accept the `security.selinux` labels they carry (mkosi drops `xattr` only for
  overlayfs destinations or uid≠0 — see `mkosi/tree.py` — which does not match
  `sudo mkosi` here). Moving the cache with `--cache-directory=` does **not**
  help: the failing destination is a container path either way.

  Fixed in `mkosi.conf` with three settings: no `CacheDirectory=`/`Incremental=`
  (throwaway temp dirs), `CacheOnly=metadata` (skips the sync), and
  `PackageCacheDirectory=/var/tmp/mkosi.pkgcache` (container-local, stays empty).
  The last one matters because mkosi 25.3 calls `copy_repository_metadata()`
  **unconditionally** — in both the incremental and non-incremental branch — so
  disabling the cache alone is not enough; the copy is only skipped when the
  source directory does not exist. Nothing is lost: under `Distribution=custom`
  `cache_subdirs()`/`state_subdirs()` are empty, and the cache that matters is
  the SDK's own binpkg cache.

  Clear stale caches once (they are root-owned and SELinux-labelled):

      sudo rm -rf mkosi.cache /var/cache/mkosi /var/tmp/mkosi.pkgcache

- **The config JSON keys are capitalised.** `jq -r '.packages[]'` yields
  `Cannot iterate over null` and silently installs **nothing**. Use `.Packages`.
  `read_list()` uses `.[$k] // []` so a missing key is empty, not null.
- **`BuildPackages=` / `VolatilePackages=` are not supported.** They route
  through the same dead `install_packages()` path as `Packages=`, but nothing
  reads them back. `tools/prepare.sh` **fails loudly** rather than shipping an
  image quietly missing them.
- **An overlay cannot express deletion.** `Overlay=yes` / `Format=sysext` builds
  a delta: the pruning step keeps only genuinely *added* files under
  `/usr`+`/opt`. `RemovePackages=` therefore only works in a tree that owns its
  content (`Format=directory` without `Overlay=yes`, so the base is *copied* in).
- **`ExtraSearchPaths=` rejects paths under `/usr`**, hence `tools/bin`.
- **`/scripts` wins over the extra paths.** This mechanism fills a gap; it cannot
  override a real backend's helper. Fine under `custom`.
- Signing keys come from the SDK (`SYSEXT_SIGNING_KEY_DIR`,
  `MODULE_SIGNING_KEY_DIR`); no keys are committed here.

## Status

Ported from the out-of-tree `flatcar_build` tree. **Verified working in the SDK
container** up to the package-install step: `Distribution=custom` →
`ExtraSearchPaths` puts `mkosi-install` on the hook PATH → `tools/prepare.sh`
reads `.Packages` from `$MKOSI_CONFIG` → dispatches to the SDK's `emerge` with
the right board, and portage resolves dependencies successfully against the
board sysroot and overlays.

**Prerequisite for a full build:** the board must actually have the OS binary
packages. A freshly set-up board only has ~22 categories (no `coreos-base`), and
the build then fails with:

    emerge: there are no binary packages to satisfy "coreos-base/coreos"

Run `./build_packages --board=amd64-usr` in the SDK first.

Still open, see `../docs/mkosi-in-sdk-implementation-draft.md`:
eselect symlinks, os-release provenance, and verity/seal
ordering.
