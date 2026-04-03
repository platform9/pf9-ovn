set -x
set -e # Recommended: Fail immediately if any command fails

source pf9-version/pf9-version.rc

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

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

# export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

git config --global --add safe.directory '*'
git config --global url."https://github.com/".insteadOf "git@github.com:"

# Cleanup: Remove previous build artifacts and the dist directory
# We run make distclean in ROOT if Makefile exists, otherwise just clean dist
if [ -f "$ROOT/Makefile" ]; then
    make -C "$ROOT" distclean
fi
rm -rf "$ROOT/dist"

# ... [Previous setup and make distclean] ...

UBUNTU_VERSION=$1
CURRENT_BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)

if [ "$UBUNTU_VERSION" = "u24" ]; then
    # Ubuntu 24.04 (Noble)
    OVS_BASE="3.3.6"
    OVN_BASE="24.03.6"

    # Case 1: Already on a u24 branch - No Switch/Fetch needed
    if echo "$CURRENT_BRANCH" | grep -q "u24"; then
        echo "Current branch '$CURRENT_BRANCH' is already a u24 branch. Keeping it."
    
    # Case 2: On a u22 branch, try to swap 'u22' for 'u24'
    elif echo "$CURRENT_BRANCH" | grep -q "u22"; then
        TARGET_BRANCH="${CURRENT_BRANCH/u22/u24}"
        echo "Current branch '$CURRENT_BRANCH' contains 'u22'. Fetching..."
        
        # Fetch before switching
        git -C "$ROOT" fetch

        echo "Attempting switch to '$TARGET_BRANCH'..."
        if git -C "$ROOT" checkout "$TARGET_BRANCH"; then
            echo "Successfully switched to specific branch '$TARGET_BRANCH'."
        else
            echo "Branch '$TARGET_BRANCH' not found. Defaulting to 'main-u24'."
            git -C "$ROOT" checkout "main-u24"
        fi
    
    # Case 3: Generic branch (no u22/u24 in name) -> Default to main-u24
    else
        echo "Current branch '$CURRENT_BRANCH' does not match u24 patterns. Fetching and defaulting to 'main-u24'."
        git -C "$ROOT" fetch
        git -C "$ROOT" checkout "main-u24"
    fi

elif [ "$UBUNTU_VERSION" = "u22" ] || [ -z "$UBUNTU_VERSION" ]; then
    # Ubuntu 22.04 (Jammy)
    OVS_BASE="3.3.1"
    OVN_BASE="24.03.2"

    # Case 1: On a u24 branch, try to swap 'u24' for 'u22'
    if echo "$CURRENT_BRANCH" | grep -q "u24"; then
        TARGET_BRANCH="${CURRENT_BRANCH/u24/u22}"
        echo "Current branch '$CURRENT_BRANCH' contains 'u24'. Fetching..."

        # Fetch before switching
        git -C "$ROOT" fetch

        echo "Attempting switch to '$TARGET_BRANCH'..."
        if git -C "$ROOT" checkout "$TARGET_BRANCH"; then
            echo "Successfully switched to specific branch '$TARGET_BRANCH'."
        else
            echo "Branch '$TARGET_BRANCH' not found. Defaulting to 'main'."
            git -C "$ROOT" checkout "main"
        fi
    
    # Case 2: Already on u22 or generic branch -> Keep it.
    else
        echo "Current branch '$CURRENT_BRANCH' is appropriate for u22. Keeping it."
    fi

else
    echo "Error: Invalid Ubuntu version '$UBUNTU_VERSION'. Expected 'u22' or 'u24'."
    exit 1
fi

# ... [Submodule update and build logic below] ...

# 2. Initialize and update submodules recursively
# Performed after branch switching to ensure correct submodules are pulled
git -C "$ROOT" submodule update --init --recursive

# --- OVN CONFIGURATION ---
PF9_OVN_BUILD_VERSION=1:${OVN_BASE}-pf9-$PF9_VERSION-$BUILD_NUMBER
if [ "$UBUNTU_VERSION" = "u22" ]; then
  printf '%s\n' "$PF9_OVN_BUILD_VERSION" > $TEAMCITY_ROOT/ovn-deb-version.txt
fi

# Update OVN files
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION+$UBUNTU_VERSION/g" "$ROOT/debian/changelog"
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION+$UBUNTU_VERSION/g" "$ROOT/configure.ac"

# --- OVS CONFIGURATION ---
# Static version (no build counter): only bump manually when OVS code changes.
# Epoch 1 beats upstream; omitting build counter means existing CI-versioned
# installs (e.g. 1:3.3.x-pf9-YYYY.M.P-NNN) are already >= this and won't upgrade.
PF9_OVS_BUILD_VERSION=1:${OVS_BASE}-pf9
if [ "$UBUNTU_VERSION" = "u22" ]; then
  printf '%s' "$PF9_OVS_BUILD_VERSION" >> $TEAMCITY_ROOT/ovn-deb-version.txt
fi

# Update OVS Changelog
sed -i "s/${OVS_BASE}-1/$PF9_OVS_BUILD_VERSION+$UBUNTU_VERSION/g" "$ROOT/ovs/debian/changelog"

# Python setuptools sanitization (Pep 440)
PF9_OVS_PYTHON_VERSION=$(echo "$PF9_OVS_BUILD_VERSION" | sed "s/^1://; s/-/./g; s/${OVS_BASE}./${OVS_BASE}+/")

# Replace the base version in configure.ac
sed -i "s/${OVS_BASE}/$PF9_OVS_PYTHON_VERSION.$UBUNTU_VERSION/g" "$ROOT/ovs/configure.ac"


# --- BUILD OVS ---
# Note: Artifacts from make debian-deb usually land in the directory ABOVE the build dir.
# Since we build in $ROOT/ovs, debs land in $ROOT.
( cd "$ROOT/ovs" && ./boot.sh )
( cd "$ROOT/ovs" && ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --enable-ssl --enable-shared )
( cd "$ROOT/ovs" && make debian && make debian-deb)

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
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc

# --- ARTIFACT COLLECTION ---
ARTIFACT_DIR="$TEAMCITY_ROOT/pkgs/$UBUNTU_VERSION"
mkdir -p "$ARTIFACT_DIR"

# Move OVS debs (from ROOT)
mv -v "$ROOT"/*.deb "$ARTIFACT_DIR"

# Move OVN debs (from ROOT/../)
# Since we are in ROOT, we use ../
mv -v ../*.deb "$ARTIFACT_DIR"


# --- CLEANUP ---
cd "$ROOT"
git reset HEAD --hard
git clean -fdx

cd "$ROOT/ovs"
git reset HEAD --hard
git clean -fdx

# Restore original branch to keep CI agent clean
git -C "$ROOT" checkout "${CURRENT_BRANCH}"

cd "$ARTIFACT_DIR"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz