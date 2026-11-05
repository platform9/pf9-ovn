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
# Version scheme: see build-common.sh. RPM Version/Release cannot contain hyphens, so
# 2:<base>-<PF9_VERSION>-<build id>-<OS> is spelled Epoch=2, Version=<base>,
# Release=<PF9_VERSION>.<build id>.<OS>. ovn-rpm-version.txt carries the full
# epoch:version-release: the role depends on "ovn = <that>", and an RPM "=" dependency
# with a release only matches that exact release (including the OS tag, r10 is the only
# RPM platform).
pf9_set_build_id
PF9_RPM_RELEASE="${PF9_VERSION}.${PF9_BUILD_ID}"
printf '%s\n' "${PF9_PKG_EPOCH}:${OVN_BASE}-${PF9_RPM_RELEASE}.${ROCKY_VERSION}" > $TEAMCITY_ROOT/ovn-rpm-version.txt

# The OVN spec's Version is the *package* version (<base>); the source tarball and the
# unpacked tree keep the binary version from configure.ac (which has ".pf9." in it, see
# pf9_patch_ovn_binary_version), so point Source/%autosetup at %{pf9binver}.
sed -i \
    -e "s/^Epoch: 1$/Epoch: ${PF9_PKG_EPOCH}/" \
    -e "s/^Version: @VERSION@$/%define pf9binver @VERSION@\nVersion: ${OVN_BASE}/" \
    -e "s/^Release: 1%{?dist}$/Release: ${PF9_RPM_RELEASE}.${ROCKY_VERSION}/" \
    -e 's/^Source: \(.*\)ovn-%{version}\.tar\.gz$/Source: \1ovn-%{pf9binver}.tar.gz/' \
    -e 's/^%autosetup -n ovn-%{version} /%autosetup -n ovn-%{pf9binver} /' \
    "$ROOT/rhel/ovn-fedora.spec.in"
grep -q '^Version: '"${OVN_BASE}"'$' "$ROOT/rhel/ovn-fedora.spec.in" \
    && grep -q '^Release: '"${PF9_RPM_RELEASE}.${ROCKY_VERSION}"'$' "$ROOT/rhel/ovn-fedora.spec.in" \
    && grep -q 'ovn-%{pf9binver}.tar.gz' "$ROOT/rhel/ovn-fedora.spec.in" \
    && grep -q '^%autosetup -n ovn-%{pf9binver} ' "$ROOT/rhel/ovn-fedora.spec.in" \
    || { echo "FATAL: could not rewrite rhel/ovn-fedora.spec.in version fields (spec changed?)" >&2; exit 1; }

# configure.ac gets the dot-separated binary version (no OS suffix)
# RPM package OS indicator comes from %{?dist} macro automatically (e.g. .el10)
pf9_patch_ovn_binary_version

# --- OVS CONFIGURATION ---
# Same scheme as OVN. PF9_OVS_BUILD_VERSION is the binary/tarball version (".pf9." kept);
# PF9_OVS_PKG_VERSION is the package epoch:version-release.
PF9_OVS_BUILD_VERSION=${OVS_BASE}.pf9.${PF9_VERSION}.${PF9_BUILD_ID}
PF9_OVS_PKG_VERSION="${PF9_PKG_EPOCH}:${OVS_BASE}-${PF9_RPM_RELEASE}.${ROCKY_VERSION}"
printf '%s' "$PF9_OVS_PKG_VERSION" >> $TEAMCITY_ROOT/ovn-rpm-version.txt

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

    # Update OVS configure.ac
    sed -i "s/${OVS_BASE}/${PF9_OVS_BUILD_VERSION}/g" "$ROOT/ovs/configure.ac"

    # Rewrite the OVS spec on the fly (submodule is not tracked): Epoch, Version=<base>,
    # Release=<PF9_VERSION>.<build id>.<OS>; the tarball/tree keep the binary version.
    OVS_SPEC="$ROOT/ovs/rhel/openvswitch-fedora.spec.in"
    sed -i \
        -e "s/^Version: @VERSION@\$/Epoch: ${PF9_PKG_EPOCH}\n%define pf9binver @VERSION@\nVersion: ${OVS_BASE}/" \
        -e "s/^Release: %{release_number}%{?dist}\$/Release: ${PF9_RPM_RELEASE}.${ROCKY_VERSION}/" \
        -e 's/^Source: \(.*\)%{name}-%{version}\.tar\.gz$/Source: \1%{name}-%{pf9binver}.tar.gz/' \
        -e 's/^%setup -q$/%setup -q -n %{name}-%{pf9binver}/' \
        "$OVS_SPEC"
    grep -q '^Epoch: '"${PF9_PKG_EPOCH}"'$' "$OVS_SPEC" \
        && grep -q '^Release: '"${PF9_RPM_RELEASE}.${ROCKY_VERSION}"'$' "$OVS_SPEC" \
        && grep -q '%{name}-%{pf9binver}.tar.gz' "$OVS_SPEC" \
        && grep -q '^%setup -q -n %{name}-%{pf9binver}$' "$OVS_SPEC" \
        || { echo "FATAL: could not rewrite $OVS_SPEC version fields (spec changed?)" >&2; exit 1; }

    ( cd "$ROOT/ovs" && ./boot.sh )
    ( cd "$ROOT/ovs" && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --enable-ssl )
    ( cd "$ROOT/ovs" && make rpm-fedora RPMBUILD_OPT="--without check" )

    pf9_pack_ovs_cache "$ROCKY_VERSION"
fi

# Install OVS RPMs required for OVN build
dnf install -y "$ROOT"/ovs/rpm/rpmbuild/RPMS/*/*.rpm || true

# --- BUILD OVN ---
cd "$ROOT"
./boot.sh

OVSDIR=$ROOT/ovs
OVSBUILDDIR="$OVSDIR"
export OVSDIR OVSBUILDDIR OVSVERSION=${PF9_OVS_BUILD_VERSION}

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
