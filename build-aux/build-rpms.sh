set -x
set -e

source pf9-version/pf9-version.rc
source "$(dirname "$0")/build-common.sh"

# Enable EPEL and CRB repos for additional packages
dnf install -y epel-release
dnf config-manager --set-enabled crb

# Install dependencies
dnf install -y \
  rpm-build rpmdevtools autoconf automake libtool gcc gcc-c++ \
  openssl openssl-devel python3-devel systemd-units checkpolicy \
  selinux-policy-devel groff graphviz libcap-ng-devel \
  unbound unbound-devel procps-ng bzip2 git createrepo_c \
  libpcap-devel numactl-devel python3-sphinx python3-sortedcontainers \
  libevent-devel json-c-devel libunwind-devel \
  desktop-file-utils libbpf-devel libxdp-devel

pf9_git_setup
pf9_reset_debug_symbols

# Cleanup: Remove previous build artifacts
if [ -f "$ROOT/Makefile" ]; then
    make -C "$ROOT" distclean
fi
rm -rf "$ROOT/dist" "$ROOT/rpm"

ROCKY_VERSION=$1

if [ "$ROCKY_VERSION" != "r10" ]; then
    echo "Error: Invalid Rocky version '$ROCKY_VERSION'. Expected 'r10'."
    exit 1
fi

# --- OVN CONFIGURATION ---
# RPM Version field does not allow hyphens; use dots throughout. The version carries the
# manual PF9_REVISION counter, not the CI build number: an unchanged counter is the same
# version and is not reinstalled on hosts.
OVN_REV=$(pf9_ovn_revision)

# configure.ac gets the dot-separated binary version (no OS suffix)
# RPM package OS indicator comes from %{?dist} macro automatically (e.g. .el10)
pf9_patch_ovn_binary_version

# --- OVS CONFIGURATION ---
# OVS's version carries the PF9_REVISION counter of the pinned ovs submodule commit, which is
# only readable once the submodule is checked out (a cache hit brings the tree with it).

# --- BUILD OVS (or reuse a prebuilt tree) ---
# try the OVS cache before paying for a full rebuild. On a miss do a submodule update, changelog and
# configure.ac version edits, boot/configure/make and packs the result for next time before moving on.
EXPECTED_OVS_SHA=$(git -C "$ROOT" rev-parse HEAD:ovs) || {
    echo "Unable to determine OVS gitlink from OVN repository"
    exit 1
}

if pf9_restore_ovs_cache "$ROCKY_VERSION" "$EXPECTED_OVS_SHA"; then
    echo "OVS: using cached build tree"
else
    echo "OVS: building from source"
    pf9_submodule_update

    OVS_REV=$(pf9_ovs_revision)
    PF9_OVS_BUILD_VERSION=${OVS_BASE}.pf9.${OVS_REV}

    # Update OVS configure.ac
    sed -i "s/${OVS_BASE}/${PF9_OVS_BUILD_VERSION}/g" "$ROOT/ovs/configure.ac"

    # Inject the package epoch into the OVS spec on the fly (submodule is not tracked)
    sed -i "s/^Version: @VERSION@/Epoch: ${PF9_PKG_EPOCH}\nVersion: @VERSION@/" "$ROOT/ovs/rhel/openvswitch-fedora.spec.in"

    ( cd "$ROOT/ovs" && ./boot.sh )
    ( cd "$ROOT/ovs" && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --enable-ssl )
    ( cd "$ROOT/ovs" && make rpm-fedora RPMBUILD_OPT="--without check" )

    pf9_pack_ovs_cache "$ROCKY_VERSION"
fi

# The OVS tree is in place now (built or cached): record both versions for the role build
# (line 1 OVN, line 2 OVS).
OVS_REV=$(pf9_ovs_revision)
printf '%s\n' "${PF9_PKG_EPOCH}:${OVN_BASE}.pf9.${OVN_REV}" > "$TEAMCITY_ROOT/ovn-rpm-version.txt"
printf '%s' "${PF9_PKG_EPOCH}:${OVS_BASE}.pf9.${OVS_REV}" >> "$TEAMCITY_ROOT/ovn-rpm-version.txt"
echo "Versions: OVN ${PF9_PKG_EPOCH}:${OVN_BASE}.pf9.${OVN_REV}  OVS ${PF9_PKG_EPOCH}:${OVS_BASE}.pf9.${OVS_REV}"

# Install OVS RPMs required for OVN build
dnf install -y "$ROOT"/ovs/rpm/rpmbuild/RPMS/*/*.rpm || true

# --- BUILD OVN ---
cd "$ROOT"
./boot.sh

OVSDIR=$ROOT/ovs
OVSBUILDDIR="$OVSDIR"
export OVSDIR OVSBUILDDIR OVSVERSION=${OVS_BASE}

./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc \
    --with-ovs-source="$OVSDIR"

make rpm-fedora RPMBUILD_OPT="--without check"

# --- DEBUG SYMBOLS (on unless PF9_DEBUG_SYMBOLS=false) ---
# rpmbuild generates -debuginfo/-debugsource RPMs; normally they are deleted below.
# When enabled, copy them aside first.
if pf9_debug_symbols_enabled; then
    DEBUGINFO_DIR="$PF9_DEBUG_DIR/${ROCKY_VERSION}-debuginfo"
    rm -rf "$DEBUGINFO_DIR"
    mkdir -p "$DEBUGINFO_DIR"
    find "$ROOT/ovs/rpm/rpmbuild/RPMS" "$ROOT/rpm/rpmbuild/RPMS" -name "*.rpm" \
        \( -name "*-debuginfo-*" -o -name "*-debugsource-*" \) \
        -exec cp -v {} "$DEBUGINFO_DIR" \;
    ls -la "$DEBUGINFO_DIR"
    pf9_pack_debug_symbols
fi

# Remove bloat packages before artifact collection
find "$ROOT/ovs/rpm/rpmbuild/RPMS" "$ROOT/rpm/rpmbuild/RPMS" -name "*.rpm" \
    \( -name "*-debuginfo-*" -o -name "*-debugsource-*" -o -name "*-devel-*" \) \
    -delete -print

# --- ARTIFACT COLLECTION ---
ARTIFACT_DIR="$TEAMCITY_ROOT/pkgs/$ROCKY_VERSION"
mkdir -p "$ARTIFACT_DIR"

# Collect OVS RPMs (exclude debug/source/devel)
find "$ROOT/ovs/rpm/rpmbuild/RPMS" -name "*.rpm" \
    ! -name "*-debuginfo-*" ! -name "*-debugsource-*" ! -name "*-devel-*" \
    -exec cp -v {} "$ARTIFACT_DIR" \;

# Collect OVN RPMs (exclude debug/source/devel)
find "$ROOT/rpm/rpmbuild/RPMS" -name "*.rpm" \
    ! -name "*-debuginfo-*" ! -name "*-debugsource-*" ! -name "*-devel-*" \
    -exec cp -v {} "$ARTIFACT_DIR" \;

ls -lh "$ARTIFACT_DIR"

# --- CLEANUP ---
pf9_build_reset

cd "$ARTIFACT_DIR"
createrepo_c .
