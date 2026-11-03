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

# --- VERSIONING ---
# Epoch 2, static package versions (no build counter). Whether an installed
# package is replaced is decided by pf9-yum from the pf9-source-sha() provide
# stamped into each package (the commit it was built from), not by version.
# Epoch 2 is required because rpm orders a static "24.03.6.pf9" BELOW every
# existing build-numbered install such as "24.03.6.pf9.2026.12.0.609" (the
# longer version string wins); without it hosts on an old build-numbered
# package would never upgrade.
PF9_PKG_EPOCH=2

# --- OVN CONFIGURATION ---
PF9_OVN_SHA=$(git -C "$ROOT" rev-parse HEAD) || {
    echo "Unable to determine the pf9-ovn commit"
    exit 1
}
export PF9_OVN_SHA
# Package Version is static. The binary/tarball version (configure.ac ->
# OVN_PACKAGE_VERSION) is derived from the commit SHA by
# pf9_patch_ovn_binary_version and passed to rpmbuild separately, because the
# spec's Version no longer follows configure.ac (see ovn-fedora.spec.in).
PF9_OVN_RPM_VERSION=${OVN_BASE}.pf9
printf '%s\n' "${PF9_PKG_EPOCH}:${PF9_OVN_RPM_VERSION}" > $TEAMCITY_ROOT/ovn-rpm-version.txt

# configure.ac gets the dot-separated binary version (no OS suffix)
# RPM package OS indicator comes from %{?dist} macro automatically (e.g. .el10)
pf9_patch_ovn_binary_version

# --- OVS CONFIGURATION ---
# Static version (no build counter), stamped with pf9-source-sha() at build time.
PF9_OVS_BUILD_VERSION=${OVS_BASE}.pf9
PF9_OVS_PKG_EVR=${PF9_PKG_EPOCH}:${PF9_OVS_BUILD_VERSION}   # OVS cache key
printf '%s' "$PF9_OVS_PKG_EVR" >> $TEAMCITY_ROOT/ovn-rpm-version.txt

# --- BUILD OVS (or reuse a prebuilt tree) ---
# try the OVS cache before paying for a full rebuild. On a miss do a submodule update, changelog and
# configure.ac version edits, boot/configure/make and packs the result for next time before moving on.
EXPECTED_OVS_SHA=$(git -C "$ROOT" rev-parse HEAD:ovs) || {
    echo "Unable to determine OVS gitlink from OVN repository"
    exit 1
}

if pf9_restore_ovs_cache "$ROCKY_VERSION" "$EXPECTED_OVS_SHA" "$PF9_OVS_PKG_EVR"; then
    echo "OVS: using cached build tree"
else
    echo "OVS: building from source"
    pf9_submodule_update

    # Update OVS configure.ac
    sed -i "s/${OVS_BASE}/${PF9_OVS_BUILD_VERSION}/g" "$ROOT/ovs/configure.ac"

    # Inject the epoch into the OVS spec on the fly (submodule is not tracked)
    sed -i "s/^Version: @VERSION@/Epoch: ${PF9_PKG_EPOCH}\nVersion: @VERSION@/" "$ROOT/ovs/rhel/openvswitch-fedora.spec.in"

    ( cd "$ROOT/ovs" && ./boot.sh )
    ( cd "$ROOT/ovs" && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --enable-ssl )
    # pf9_source_sha stamps a pf9-source-sha(<commit>) provide into the packages
    ( cd "$ROOT/ovs" && make rpm-fedora RPMBUILD_OPT="--without check --define 'pf9_source_sha $EXPECTED_OVS_SHA'" )

    pf9_pack_ovs_cache "$ROCKY_VERSION"
fi

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

make rpm-fedora RPMBUILD_OPT="--without check --define 'pf9_source_sha $PF9_OVN_SHA' --define 'pf9_rpm_version $PF9_OVN_RPM_VERSION'"

# --- VERIFY the SHA stamp, static versions and the northd/controller version ---
# 1. Every OVN/OVS package pf9-yum manages must provide pf9-source-sha(<commit>);
#    pf9-yum refuses to replace an installed package with an unstamped one.
# 2. Package version must be the static epoch-2 string.
# 3. ovn-controller (ovn-host) and ovn-northd (ovn-central, run in the DU's
#    pf9-ovn container) must embed the same commit-derived version: hosts run
#    with ovn-match-northd-version=true and the DU is upgraded first.
EXPECTED_BIN_VERSION="${OVN_BASE}.pf9.${PF9_OVN_SHA:0:12}"
VERIFY_DIR=$(mktemp -d)
for rpm in "$ROOT"/rpm/rpmbuild/RPMS/*/ovn-[0-9]*.rpm "$ROOT"/rpm/rpmbuild/RPMS/*/ovn-host-*.rpm \
           "$ROOT"/rpm/rpmbuild/RPMS/*/ovn-central-*.rpm; do
    case "$rpm" in *debuginfo*|*debugsource*|*devel*) continue ;; esac
    rpm -qp --provides "$rpm" | grep -qxF "pf9-source-sha(${PF9_OVN_SHA})" || {
        echo "FATAL: $(basename "$rpm") does not provide pf9-source-sha(${PF9_OVN_SHA})"; exit 1; }
    got_evr=$(rpm -qp --qf '%{EPOCH}:%{VERSION}' "$rpm")
    [ "$got_evr" = "${PF9_PKG_EPOCH}:${PF9_OVN_RPM_VERSION}" ] || {
        echo "FATAL: $(basename "$rpm") is $got_evr, expected ${PF9_PKG_EPOCH}:${PF9_OVN_RPM_VERSION}"; exit 1; }
    (cd "$VERIFY_DIR" && rpm2cpio "$rpm" | cpio -idm --quiet)
done
for bin in ovn-controller ovn-northd; do
    path=$(find "$VERIFY_DIR" -type f -name "$bin" | head -1)
    [ -n "$path" ] || { echo "FATAL: $bin not found in the built RPMs"; exit 1; }
    if ! grep -qaF "$EXPECTED_BIN_VERSION" "$path" \
       && ! grep -rqaF "$EXPECTED_BIN_VERSION" "$VERIFY_DIR"/usr/lib* 2>/dev/null; then
        echo "FATAL: $bin does not embed version '$EXPECTED_BIN_VERSION'"; exit 1
    fi
done
for rpm in "$ROOT"/ovs/rpm/rpmbuild/RPMS/*/openvswitch-[0-9]*.rpm "$ROOT"/ovs/rpm/rpmbuild/RPMS/*/python3-openvswitch-*.rpm; do
    rpm -qp --provides "$rpm" | grep -qxF "pf9-source-sha(${EXPECTED_OVS_SHA})" || {
        echo "FATAL: $(basename "$rpm") does not provide pf9-source-sha(${EXPECTED_OVS_SHA})"; exit 1; }
done
echo "Verified: pf9-source-sha stamped, static epoch-${PF9_PKG_EPOCH} versions, controller/northd embed $EXPECTED_BIN_VERSION"
rm -rf "$VERIFY_DIR"

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
