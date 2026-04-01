set -x
set -e

source pf9-version/pf9-version.rc

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

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

git config --global --add safe.directory '*'
git config --global url."https://github.com/".insteadOf "git@github.com:"

# Cleanup: Remove previous build artifacts
if [ -f "$ROOT/Makefile" ]; then
    make -C "$ROOT" distclean
fi
rm -rf "$ROOT/dist" "$ROOT/rpm"

ROCKY_VERSION=$1
CURRENT_BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)

if [ "$ROCKY_VERSION" = "r10" ]; then
    # Rocky Linux 10.1
    OVS_BASE="3.3.6"
    OVN_BASE="24.03.6"

    # Case 1: Already on an r10 branch - No Switch/Fetch needed
    if echo "$CURRENT_BRANCH" | grep -q "r10"; then
        echo "Current branch '$CURRENT_BRANCH' is already an r10 branch. Keeping it."

    # Case 2: On a u24 branch, try to swap 'u24' for 'r10'
    elif echo "$CURRENT_BRANCH" | grep -q "u24"; then
        TARGET_BRANCH="${CURRENT_BRANCH/u24/r10}"
        echo "Current branch '$CURRENT_BRANCH' contains 'u24'. Fetching..."
        git -C "$ROOT" fetch

        echo "Attempting switch to '$TARGET_BRANCH'..."
        if git -C "$ROOT" checkout "$TARGET_BRANCH"; then
            echo "Successfully switched to '$TARGET_BRANCH'."
        else
            echo "Branch '$TARGET_BRANCH' not found. Defaulting to 'main-r10'."
            git -C "$ROOT" checkout "main-r10"
        fi

    # Case 3: On a u22 branch, try to swap 'u22' for 'r10'
    elif echo "$CURRENT_BRANCH" | grep -q "u22"; then
        TARGET_BRANCH="${CURRENT_BRANCH/u22/r10}"
        echo "Current branch '$CURRENT_BRANCH' contains 'u22'. Fetching..."
        git -C "$ROOT" fetch

        echo "Attempting switch to '$TARGET_BRANCH'..."
        if git -C "$ROOT" checkout "$TARGET_BRANCH"; then
            echo "Successfully switched to '$TARGET_BRANCH'."
        else
            echo "Branch '$TARGET_BRANCH' not found. Defaulting to 'main-r10'."
            git -C "$ROOT" checkout "main-r10"
        fi

    # Case 4: Generic branch -> Default to main-r10
    else
        echo "Current branch '$CURRENT_BRANCH' does not match r10 patterns. Fetching and defaulting to 'main-r10'."
        git -C "$ROOT" fetch
        git -C "$ROOT" checkout "main-r10"
    fi

else
    echo "Error: Invalid Rocky version '$ROCKY_VERSION'. Expected 'r10'."
    exit 1
fi

# Initialize and update submodules
git -C "$ROOT" submodule update --init --recursive

# --- OVN CONFIGURATION ---
# RPM Version field does not allow hyphens; use dots throughout
PF9_OVN_BUILD_VERSION=${OVN_BASE}.pf9.${PF9_VERSION}.${BUILD_NUMBER}.${ROCKY_VERSION}
printf '%s\n' "$PF9_OVN_BUILD_VERSION" > $TEAMCITY_ROOT/ovn-rpm-version.txt

# Update OVN configure.ac
sed -i "s/__PF9_OVN_BUILD_VERSION__/${PF9_OVN_BUILD_VERSION}/g" "$ROOT/configure.ac"

# --- OVS CONFIGURATION ---
PF9_OVS_BUILD_VERSION=${OVS_BASE}.pf9.${PF9_VERSION}.${BUILD_NUMBER}.${ROCKY_VERSION}
printf '%s' "$PF9_OVS_BUILD_VERSION" >> $TEAMCITY_ROOT/ovn-rpm-version.txt

# Update OVS configure.ac
sed -i "s/${OVS_BASE}/${PF9_OVS_BUILD_VERSION}/g" "$ROOT/ovs/configure.ac"

# --- BUILD OVS ---
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

# --- ARTIFACT COLLECTION ---
ARTIFACT_DIR="$TEAMCITY_ROOT/pkgs/$ROCKY_VERSION"
mkdir -p "$ARTIFACT_DIR"

# Collect OVS RPMs
find "$ROOT/ovs/rpm/rpmbuild/RPMS" -name "*.rpm" -exec cp -v {} "$ARTIFACT_DIR" \;

# Collect OVN RPMs
find "$ROOT/rpm/rpmbuild/RPMS" -name "*.rpm" -exec cp -v {} "$ARTIFACT_DIR" \;

ls -lh "$ARTIFACT_DIR"

# --- CLEANUP ---
cd "$ROOT"
git reset HEAD --hard
git clean -fdx

cd "$ROOT/ovs"
git reset HEAD --hard
git clean -fdx

git -C "$ROOT" checkout "${CURRENT_BRANCH}"

cd "$ARTIFACT_DIR"
createrepo_c .
