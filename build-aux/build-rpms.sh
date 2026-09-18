set -x
set -e

source pf9-version/pf9-version.rc
source "$(dirname "$0")/build-common.sh"

# Install dependencies (list shared with build-ovs.sh, see build-common.sh)
pf9_install_build_deps_rpm

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
printf '%s\n' "1:${OVN_BASE}.pf9.${PF9_VERSION}.${BUILD_NUMBER}" > $TEAMCITY_ROOT/ovn-rpm-version.txt

# configure.ac gets the dot-separated binary version (no OS suffix)
# RPM package OS indicator comes from %{?dist} macro automatically (e.g. .el10)
pf9_patch_ovn_binary_version

# --- OVS CONFIGURATION ---
# Static version (no build counter): only bump manually when OVS code changes
PF9_OVS_BUILD_VERSION=$(pf9_ovs_build_version "$ROCKY_VERSION")
printf '%s' "1:$PF9_OVS_BUILD_VERSION" >> $TEAMCITY_ROOT/ovn-rpm-version.txt

# --- BUILD OVS (or reuse a prebuilt tree) ---
# Build 5132375: rebuilding the static-version OVS costs ~7 of ~18 min per
# platform. If the TC artifact dependency dropped a matching
# ovs-cache/ovs-build-r10.tar.gz (produced by build-ovs.sh) we restore it
# instead (tree incl. ovs/rpm/rpmbuild/RPMS). The configure.ac/spec Epoch seds
# live in pf9_patch_ovs_version_rpm and are applied ONLY on the from-source
# path: a cached tree was already patched by the producer. Without ovs-cache/
# this behaves exactly as before.
if pf9_restore_ovs_cache "$ROCKY_VERSION"; then
    echo "OVS: using cached build tree"
else
    echo "OVS: building from source"
    pf9_patch_ovs_version_rpm
    pf9_build_ovs_rpm
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
