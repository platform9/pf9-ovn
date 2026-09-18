set -x
set -e

source pf9-version/pf9-version.rc
source "$(dirname "$0")/build-common.sh"

# Install dependencies (list shared with build-ovs.sh, see build-common.sh)
pf9_install_build_deps_deb

pf9_git_setup

# Cleanup: Remove previous build artifacts
if [ -f "$ROOT/Makefile" ]; then
    make -C "$ROOT" distclean
fi
rm -rf "$ROOT/dist"

UBUNTU_VERSION=$1

if [ "$UBUNTU_VERSION" != "u22" ] && [ "$UBUNTU_VERSION" != "u24" ] && [ -n "$UBUNTU_VERSION" ]; then
    echo "Error: Invalid Ubuntu version '$UBUNTU_VERSION'. Expected 'u22' or 'u24'."
    exit 1
fi

pf9_submodule_update

# --- OVN CONFIGURATION ---
PF9_OVN_BUILD_VERSION=1:${OVN_BASE}-pf9-$PF9_VERSION-$BUILD_NUMBER+${UBUNTU_VERSION}
printf '%s\n' "1:${OVN_BASE}-pf9-${PF9_VERSION}-${BUILD_NUMBER}" > $TEAMCITY_ROOT/ovn-deb-version.txt

# debian/changelog gets the full epoch-prefixed version for apt dependency resolution
# configure.ac gets the dot-separated binary version via pf9_patch_ovn_binary_version
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION/g" "$ROOT/debian/changelog"

pf9_patch_ovn_binary_version

# --- OVS CONFIGURATION ---
# Static version (no build counter): only bump manually when OVS code changes.
# Epoch 1 beats upstream; omitting build counter means existing CI-versioned
# installs (e.g. 1:3.3.x-pf9-YYYY.M.P-NNN) are already >= this and won't upgrade.
PF9_OVS_BUILD_VERSION=$(pf9_ovs_build_version "$UBUNTU_VERSION")
printf '%s' "1:${OVS_BASE}-pf9" >> $TEAMCITY_ROOT/ovn-deb-version.txt

# --- BUILD OVS (or reuse a prebuilt tree) ---
# Build 5132375: OVS boot/configure/dist 2.2 + make -j8 3.6 + install/dh/debs
# 1.0 = ~7 of ~18 min per platform, for a static OVS version. If the TC
# artifact dependency dropped a matching ovs-cache/ovs-build-<plat>.tar.gz
# (produced by build-ovs.sh) we restore it instead. The version seds live in
# pf9_patch_ovs_version_deb and are applied ONLY on the from-source path: a
# cached tree was already patched by the producer. Without ovs-cache/ this
# behaves exactly as before.
if pf9_restore_ovs_cache "$UBUNTU_VERSION"; then
    echo "OVS: using cached build tree"
else
    echo "OVS: building from source"
    pf9_patch_ovs_version_deb
    pf9_build_ovs_deb
fi

# Install OVS dependencies required for OVN build
cd "$ROOT"
dpkg -i "$ROOT"/openvswitch-*.deb "$ROOT"/python3-openvswitch_*.deb \
       "$ROOT"/openvswitch-common_*.deb "$ROOT"/openvswitch-switch_*.deb \
       "$ROOT"/openvswitch-ipsec_*.deb "$ROOT"/openvswitch-vtep_*.deb \
       "$ROOT"/openvswitch-testcontroller_*.deb "$ROOT"/openvswitch-pki_*.deb \
       "$ROOT"/openvswitch-doc_*.deb "$ROOT"/openvswitch-source_*.deb || true

# --- BUILD OVN ---
cd "$ROOT"
./boot.sh || true

OVSDIR=$ROOT/ovs
OVSBUILDDIR="$OVSDIR/_debian"

# Sanity check
test -f "$OVSBUILDDIR/config.status" || { echo "OVS not configured at $OVSBUILDDIR"; exit 1; }

export OVSDIR OVSBUILDDIR EXTRA_CONFIGURE_OPTS="--with-ovs-build=$OVSBUILDDIR"

# Build OVN Debs (Artifacts land in parent of $ROOT, i.e., $ROOT/../)
# Build 5132375: OVN compile took 5.8 min because debian/rules defers the
# compile to dh_auto_install, and without parallel=N in DEB_BUILD_OPTIONS
# `dh --parallel` runs `make -j1`. OVS's own debian-deb target already passes
# parallel=$(nproc); do the same here (-j is belt and braces: dpkg-buildpackage
# adds parallel=N itself if absent). noautodbgsym skips building the -dbgsym
# packages that are deleted below anyway; nodoc deliberately NOT added because
# debhelper's nodoc also skips dh_installman and would drop the man pages
# shipped in ovn-common/ovn-host/ovn-central.
DEB_BUILD_OPTIONS="nocheck noautodbgsym parallel=$(nproc)" dpkg-buildpackage -b -us -uc -j"$(nproc)"

# Remove bloat packages before artifact collection
find "$ROOT" "$TEAMCITY_ROOT" -maxdepth 1 -name "*.deb" \
    \( -name "*-doc_*" -o -name "*-source_*" -o -name "*-test_*" \
       -o -name "*-testcontroller_*" -o -name "*-dbgsym_*" \) \
    -delete -print

# --- ARTIFACT COLLECTION ---
ARTIFACT_DIR="$TEAMCITY_ROOT/pkgs/$UBUNTU_VERSION"
mkdir -p "$ARTIFACT_DIR"

# Move OVS debs (exclude doc/source/test/dbgsym)
find "$ROOT" -maxdepth 1 -name "*.deb" \
    ! -name "*-doc_*" ! -name "*-source_*" \
    ! -name "*-test_*" ! -name "*-testcontroller_*" ! -name "*-dbgsym_*" \
    -exec mv -v {} "$ARTIFACT_DIR" \;

# Move OVN debs (from ROOT/../, exclude doc/source/test/dbgsym)
find "$TEAMCITY_ROOT" -maxdepth 1 -name "*.deb" \
    ! -name "*-doc_*" ! -name "*-source_*" \
    ! -name "*-test_*" ! -name "*-testcontroller_*" ! -name "*-dbgsym_*" \
    -exec mv -v {} "$ARTIFACT_DIR" \;


# --- CLEANUP ---
pf9_build_reset

cd "$ARTIFACT_DIR"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz