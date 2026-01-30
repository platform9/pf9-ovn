set -x

source pf9-version/pf9-version.rc

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

# Cleanup: Remove previous build artifacts and the dist directory
make distclean

UBUNTU_VERSION=$1
CURRENT_BRANCH="%teamcity.build.branch%"

# 1. Determine versions and switch branches based on naming convention
if [ "$UBUNTU_VERSION" = "u24" ]; then
    # Ubuntu 24.04 (Noble)
    OVS_BASE="3.3.6"
    OVN_BASE="24.03.6"

    # Logic: If current branch name does NOT contain "u24"
    if echo "$CURRENT_BRANCH" | grep -qv "u24"; then
        echo "Current branch '$CURRENT_BRANCH' does not contain 'u24'."
        
        # Attempt to checkout the specific <branch>-u24 variant
        if git checkout "${CURRENT_BRANCH}-u24"; then
            echo "Successfully switched to specific branch '${CURRENT_BRANCH}-u24'."
        else
            echo "Specific branch '${CURRENT_BRANCH}-u24' not found. Defaulting to 'main-u24'."
            git checkout "main-u24"
        fi
    else
        echo "Current branch '$CURRENT_BRANCH' is already a u24 branch. Keeping it."
    fi

elif [ "$UBUNTU_VERSION" = "u22" ] || [ -z "$UBUNTU_VERSION" ]; then
    # Ubuntu 22.04 (Jammy) - Defaulting to u22 if empty
    OVS_BASE="3.3.1"
    OVN_BASE="24.03.2"

    # Logic: If current branch name DOES contain "u24", switch to 'main' (for u22 build)
    if echo "$CURRENT_BRANCH" | grep -q "u24"; then
        echo "Current branch '$CURRENT_BRANCH' contains 'u24' but targeting u22. Switching to 'main'."
        git checkout "main"
    else
        echo "Current branch '$CURRENT_BRANCH' is appropriate for u22. Keeping it."
    fi

else
    echo "Error: Invalid Ubuntu version '$UBUNTU_VERSION'. Expected 'u22' or 'u24'."
    exit 1
fi

# 2. Initialize and update submodules recursively
# Performed after branch switching to ensure correct submodules are pulled
git submodule update --init --recursive

# --- OVN CONFIGURATION ---
PF9_OVN_BUILD_VERSION=1:${OVN_BASE}-pf9-$PF9_VERSION-$BUILD_NUMBER
if [ "$UBUNTU_VERSION" = "u22" ]; then
  printf '%s\n' "$PF9_OVN_BUILD_VERSION" > $TEAMCITY_ROOT/ovn-deb-version.txt
fi

# Update OVN files
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION+$UBUNTU_VERSION/g" $ROOT/debian/changelog
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION+$UBUNTU_VERSION/g" $ROOT/configure.ac

# --- OVS CONFIGURATION ---

PF9_OVS_BUILD_VERSION=1:${OVS_BASE}-pf9-$PF9_VERSION-$BUILD_NUMBER
if [ "$UBUNTU_VERSION" = "u22" ]; then
  printf '%s' "$PF9_OVS_BUILD_VERSION" >> $TEAMCITY_ROOT/ovn-deb-version.txt
fi
# Update OVS Changelog
# NOTE: This uses ${OVS_BASE}-1 as the search pattern (e.g. searching for 3.3.1-1 or 3.3.4-1)
sed -i "s/${OVS_BASE}-1/$PF9_OVS_BUILD_VERSION+$UBUNTU_VERSION/g" $ROOT/ovs/debian/changelog

# Python setuptools (used in OVS build) requires PEP 440 compliant version.
# We sanitize the version by removing epoch and replacing hyphens with dots or +
# 1:3.3.1-pf9... -> 3.3.1+pf9...
# 1. Remove '1:' (epoch)
# 2. Replace all '-' with '.'
# 3. Replace the first dot after the base version (e.g. "3.3.6.") with a "+" ("3.3.6+")
#    to strictly adhere to local version identifier rules.
PF9_OVS_PYTHON_VERSION=$(echo "$PF9_OVS_BUILD_VERSION" | sed "s/^1://; s/-/./g; s/${OVS_BASE}./${OVS_BASE}+/")

# Replace the base version in configure.ac with the full sanitized Python version
sed -i "s/${OVS_BASE}/$PF9_OVS_PYTHON_VERSION.$UBUNTU_VERSION/g" $ROOT/ovs/configure.ac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  fakeroot build-essential autoconf automake bzip2 debhelper devscripts dpkg-dev \
  debhelper-compat dh-exec dh-python dh-sequence-python3 dh-sequence-sphinxdoc \
  graphviz iproute2 libcap-ng-dev libnuma-dev libpcap-dev libssl-dev libtool \
  libunbound-dev openssl pkg-config procps python3-all-dev python3-setuptools \
  python3-sortedcontainers python3-sphinx libjson-c-dev libevent-dev \
  libsystemd-dev python3 python3-pip curl python3-twisted python3-zope.interface \
  libunwind-dev git strongswan kmod uuid-runtime python3-netifaces

git config --global --add safe.directory '*'



# In pf9-ovn/ovs
( cd "$ROOT/ovs" && ./boot.sh )
( cd "$ROOT/ovs" && ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --enable-ssl --enable-shared )
( cd "$ROOT/ovs" && make debian && make debian-deb)

cd $ROOT
dpkg -i "$ROOT"/openvswitch-*.deb "$ROOT"/python3-openvswitch_*.deb \
       "$ROOT"/openvswitch-common_*.deb "$ROOT"/openvswitch-switch_*.deb \
       "$ROOT"/openvswitch-ipsec_*.deb "$ROOT"/openvswitch-vtep_*.deb \
       "$ROOT"/openvswitch-testcontroller_*.deb "$ROOT"/openvswitch-pki_*.deb \
       "$ROOT"/openvswitch-doc_*.deb "$ROOT"/openvswitch-source_*.deb || true

cd $ROOT
./boot.sh || true
# If you built OVS with dpkg-buildpackage, its configured build dir is ovs/_debian
OVSDIR=$ROOT/ovs
OVSBUILDDIR="$OVSDIR/_debian"

# sanity check that it's a configured tree
test -f "$OVSBUILDDIR/config.status" || { echo "OVS not configured at $OVSBUILDDIR"; exit 1; }

# export so make sees them
export OVSDIR OVSBUILDDIR EXTRA_CONFIGURE_OPTS="--with-ovs-build=$OVSBUILDDIR"


DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc

ARTIFACT_DIR="$TEAMCITY_ROOT/pkgs/$UBUNTU_VERSION"
mkdir -p $ARTIFACT_DIR
mv -v "$ROOT"/*.deb $ARTIFACT_DIR
mv -v ../*.deb $ARTIFACT_DIR

# clean up the build
cd $ROOT
git reset HEAD --hard
git clean -fdx

cd $ROOT/ovs
git reset HEAD --hard
git clean -fdx

cd $ARTIFACT_DIR
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz