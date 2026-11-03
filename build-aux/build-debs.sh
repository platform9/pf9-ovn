set -x
set -e

source pf9-version/pf9-version.rc
source "$(dirname "$0")/build-common.sh"

# Install dependencies
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  fakeroot build-essential autoconf automake bzip2 debhelper devscripts dpkg-dev \
  debhelper-compat dh-exec dh-python dh-sequence-python3 dh-sequence-sphinxdoc \
  graphviz iproute2 libcap-ng-dev libnuma-dev libpcap-dev libssl-dev libtool \
  libunbound-dev openssl pkg-config procps python3-all-dev python3-setuptools \
  python3-sortedcontainers python3-sphinx libjson-c-dev libevent-dev \
  libsystemd-dev python3 python3-pip curl python3-twisted python3-zope.interface \
  libunwind-dev git strongswan kmod uuid-runtime python3-netifaces

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

# --- VERSIONING ---
# Epoch 2, no build counter: the deb version is static per base version and OS.
# Whether an installed package is replaced is decided by pf9-apt from the
# Pf9-Source-Sha deb field (the commit the package was built from), not by
# the version string. Epoch 2 is required because dpkg orders a static
# "24.03.6-pf9+u22" BELOW every existing build-numbered install such as
# "24.03.6-pf9-2026.12.0-609+u22" (a shorter upstream_version sorts lower);
# without it, hosts on an old build-numbered package would never upgrade.
PF9_PKG_EPOCH=2

# --- OVN CONFIGURATION ---
PF9_OVN_SHA=$(git -C "$ROOT" rev-parse HEAD) || {
    echo "Unable to determine the pf9-ovn commit"
    exit 1
}
PF9_OVN_BUILD_VERSION=${PF9_PKG_EPOCH}:${OVN_BASE}-pf9+${UBUNTU_VERSION}
printf '%s\n' "${PF9_PKG_EPOCH}:${OVN_BASE}-pf9" > $TEAMCITY_ROOT/ovn-deb-version.txt
export PF9_OVN_SHA

# debian/changelog gets the full epoch-prefixed version for apt dependency resolution
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION/g" "$ROOT/debian/changelog"

# configure.ac gets the dot-separated version the binaries report
# (ovn-appctl version); unrelated to the package version above
pf9_patch_ovn_binary_version

# --- OVS CONFIGURATION ---
# Static version (no build counter), stamped with Pf9-Source-Sha at build time
# (pf9-ovs debian/rules). See the epoch note above.
PF9_OVS_BUILD_VERSION=${PF9_PKG_EPOCH}:${OVS_BASE}-pf9+${UBUNTU_VERSION}
PF9_OVS_PKG_EVR=$PF9_OVS_BUILD_VERSION   # OVS cache key (see pf9_pack_ovs_cache)
printf '%s' "${PF9_PKG_EPOCH}:${OVS_BASE}-pf9" >> $TEAMCITY_ROOT/ovn-deb-version.txt

# --- BUILD OVS (or reuse a prebuilt tree) ---
# try the OVS cache before paying for a full rebuild. On a miss do a submodule update, changelog and
# configure.ac version edits, boot/configure/make and packs the result for next time before moving on.
EXPECTED_OVS_SHA=$(git -C "$ROOT" rev-parse HEAD:ovs) || {
    echo "Unable to determine OVS gitlink from OVN repository"
    exit 1
}

if pf9_restore_ovs_cache "$UBUNTU_VERSION" "$EXPECTED_OVS_SHA" "$PF9_OVS_PKG_EVR"; then
    echo "OVS: using cached build tree"
else
    echo "OVS: building from source"
    pf9_submodule_update

    # Update OVS Changelog
    sed -i "s/${OVS_BASE}-1/$PF9_OVS_BUILD_VERSION/g" "$ROOT/ovs/debian/changelog"

    # Python setuptools sanitization (PEP 440)
    # Strip epoch and +UBUNTU_VERSION before converting to dot-notation, then re-add + for local segment
    PF9_OVS_PYTHON_VERSION=$(echo "$PF9_OVS_BUILD_VERSION" | sed "s/^[0-9]*://; s/+[^-]*$//; s/-/./g; s/${OVS_BASE}./${OVS_BASE}+/")
    sed -i "s/${OVS_BASE}/$PF9_OVS_PYTHON_VERSION/g" "$ROOT/ovs/configure.ac"

    # Note: Artifacts from make debian-deb usually land in the directory ABOVE the build dir.
    # Since we build in $ROOT/ovs, debs land in $ROOT.
    ( cd "$ROOT/ovs" && ./boot.sh )
    ( cd "$ROOT/ovs" && ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --enable-ssl --enable-shared )
    # Stamp the pf9-ovs commit into the debs as 'Pf9-Source-Sha' (see
    # pf9-ovs debian/rules). pf9-apt uses it to decide whether an OVS package
    # with an unchanged version string still needs upgrading.
    ( cd "$ROOT/ovs" && PF9_OVS_SHA="$EXPECTED_OVS_SHA" make debian && PF9_OVS_SHA="$EXPECTED_OVS_SHA" make debian-deb)

    pf9_pack_ovs_cache "$UBUNTU_VERSION"
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

# ./boot.sh above ran plain libtoolize, which drops its own fresh
# build-aux/ltmain.sh. dpkg-buildpackage's first action is 'debian/rules
# clean', which runs dh_autoreconf_clean (debhelper's --with autoreconf
# addon) - that unconditionally tries to reverse dh-autoreconf's own
# ltmain-as-needed.diff quirk-patch against whatever ltmain.sh it finds, and
# fails because this one was never patched by dh_autoreconf in the first
# place (different libtool version, different output). Removing it here lets
# dh_autoreconf regenerate + patch its own copy from scratch during the
# build phase that follows, instead of 2-out-of-2 hunks failing (and the
# whole build dying) at the clean phase before any of that ever happens.
rm -f build-aux/ltmain.sh

# Build OVN Debs (Artifacts land in parent of $ROOT, i.e., $ROOT/../)
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc

# --- VERIFY the Pf9-Source-Sha stamp ---
# Every OVN deb must carry the pf9-ovn commit as Pf9-Source-Sha; pf9-apt
# refuses to replace an installed package with an unstamped one.
VERIFY_SHA_FAIL=0
for pkg in ovn-common ovn-host ovn-central; do
    deb=$(ls "$TEAMCITY_ROOT"/${pkg}_*.deb | head -1)
    got_sha=$(dpkg-deb -f "$deb" Pf9-Source-Sha)
    if [ "$got_sha" != "$PF9_OVN_SHA" ]; then
        echo "FATAL: $(basename "$deb") Pf9-Source-Sha='$got_sha', expected '$PF9_OVN_SHA'"
        VERIFY_SHA_FAIL=1
    fi
done
[ "$VERIFY_SHA_FAIL" = 0 ] || exit 1
echo "Verified: Pf9-Source-Sha=${PF9_OVN_SHA:0:12} on ovn-common/ovn-host/ovn-central"

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