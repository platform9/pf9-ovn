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

pf9_submodule_update

# --- OVN CONFIGURATION ---
# RPM Version field does not allow hyphens; use dots throughout
PF9_OVN_BUILD_VERSION=${OVN_BASE}.pf9.${PF9_VERSION}.${BUILD_NUMBER}.${ROCKY_VERSION}
printf '%s\n' "1:$PF9_OVN_BUILD_VERSION" > $TEAMCITY_ROOT/ovn-rpm-version.txt

# Update OVN configure.ac
sed -i "s/__PF9_OVN_BUILD_VERSION__/${PF9_OVN_BUILD_VERSION}/g" "$ROOT/configure.ac"

# --- OVS CONFIGURATION ---
# Static version (no build counter): only bump manually when OVS code changes
PF9_OVS_BUILD_VERSION=${OVS_BASE}.pf9.${ROCKY_VERSION}
printf '%s' "1:$PF9_OVS_BUILD_VERSION" >> $TEAMCITY_ROOT/ovn-rpm-version.txt

# Update OVS configure.ac
sed -i "s/${OVS_BASE}/${PF9_OVS_BUILD_VERSION}/g" "$ROOT/ovs/configure.ac"

# --- BUILD OVS ---
# Inject Epoch: 1 into the OVS spec on the fly (submodule is not tracked)
sed -i 's/^Version: @VERSION@/Epoch: 1\nVersion: @VERSION@/' "$ROOT/ovs/rhel/openvswitch-fedora.spec.in"

( cd "$ROOT/ovs" && ./boot.sh )
( cd "$ROOT/ovs" && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --enable-ssl )
( cd "$ROOT/ovs" && make rpm-fedora RPMBUILD_OPT="--without check" )

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
