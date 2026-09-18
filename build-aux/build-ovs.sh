set -x
set -e

# build-ovs.sh <u22|u24|r10>
#
# Producer for the prebuilt OVS cache consumed by build-debs.sh / build-rpms.sh
# (pf9_restore_ovs_cache). Build 5132375 spent ~7 of ~18 min per platform
# rebuilding OVS 3.3.6, whose pf9 package version is static (no build
# counter). This script builds OVS exactly the way those scripts do -- same
# deps, same submodule checkout, same version seds, same boot/configure/make --
# and packs the resulting tree + packages into
#     $TEAMCITY_ROOT/ovs-build-<plat>.tar.gz
# A consumer build reuses it only when ROOT, PLAT, OVS_BASE and the ovs
# submodule SHA all match (see pf9_restore_ovs_cache in build-common.sh).
#
# Expected TC layout, identical to the other build scripts:
#   cwd            = $TEAMCITY_ROOT (agent checkout dir)
#   pf9-ovn/       = this repo, with the ovs/ submodule
#   pf9-version/   = optional here (OVS version does not use PF9_VERSION)

# pf9-version is what build-debs.sh/build-rpms.sh source for PF9_VERSION /
# BUILD_NUMBER; the OVS version is static and does not need it, so tolerate a
# TC config that does not check it out.
if [ -f pf9-version/pf9-version.rc ]; then
    source pf9-version/pf9-version.rc
fi
source "$(dirname "$0")/build-common.sh"

PLAT=$1

case "$PLAT" in
    u22|u24) FLAVOR=deb ;;
    r10)     FLAVOR=rpm ;;
    *)
        echo "Error: Invalid platform '$PLAT'. Expected 'u22', 'u24' or 'r10'."
        exit 1
        ;;
esac

# Install dependencies (same lists as build-debs.sh / build-rpms.sh)
"pf9_install_build_deps_$FLAVOR"

pf9_git_setup

# Cleanup: remove leftovers a previous (possibly failed) run may have left in
# $ROOT, so stale OVS packages can never be packed into the cache.
if [ -f "$ROOT/Makefile" ]; then
    make -C "$ROOT" distclean
fi
rm -rf "$ROOT/dist" "$ROOT/rpm"
rm -f "$ROOT"/*.deb "$ROOT"/*.ddeb "$ROOT"/*.changes "$ROOT"/*.buildinfo
rm -f "$TEAMCITY_ROOT/ovs-build-${PLAT}.tar.gz"

pf9_submodule_update

# --- OVS CONFIGURATION ---
# Static version (no build counter): only bump manually when OVS code changes.
# Same edits build-debs.sh / build-rpms.sh apply on their from-source path.
PF9_OVS_BUILD_VERSION=$(pf9_ovs_build_version "$PLAT")
"pf9_patch_ovs_version_$FLAVOR"

# --- BUILD OVS ---
"pf9_build_ovs_$FLAVOR"

# --- PACK CACHE ---
# Must run BEFORE pf9_build_reset: that wipes the tree we are caching.
pf9_pack_ovs_cache "$PLAT"

# --- CLEANUP ---
pf9_build_reset
