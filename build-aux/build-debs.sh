set -x

source pf9-version/pf9-version.rc

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

make distclean

UBUNTU_VERSION=$1


PF9_OVN_BUILD_VERSION=1:24.03.2-pf9-$PF9_VERSION-$BUILD_NUMBER
printf '%s\n' "$PF9_OVN_BUILD_VERSION" > $ROOT/ovn-deb-version.txt

sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION+$UBUNTU_VERSION/g" $ROOT/debian/changelog
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION+$UBUNTU_VERSION/g" $ROOT/configure.ac

PF9_OVS_BUILD_VERSION=1:3.3.1-pf9-$PF9_VERSION-$BUILD_NUMBER
printf '%s' "$PF9_OVS_BUILD_VERSION" >> $ROOT/ovn-deb-version.txt
cat ovn-deb-version.txt

sed -i "s/3.3.1-1/$PF9_OVS_BUILD_VERSION+$UBUNTU_VERSION/g" $ROOT/ovs/debian/changelog

# Python setuptools (used in OVS build) requires PEP 440 compliant version.
# We sanitize the version by removing epoch and replacing hyphens with dots or +
# 1:3.3.1-pf9... -> 3.3.1+pf9...
PF9_OVS_PYTHON_VERSION=$(echo "$PF9_OVS_BUILD_VERSION" | sed 's/^1://; s/-/./g; s/3.3.1./3.3.1+/')
sed -i "s/3.3.1/$PF9_OVS_PYTHON_VERSION.$UBUNTU_VERSION/g" $ROOT/ovs/configure.ac

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