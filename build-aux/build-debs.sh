set -x

#source pf9-version/pf9-version.rc

ROOT="$(pwd)/pf9-ovn"


PF9_OVN_BUILD_VERSION=24.03.2-pf9-$BUILD_NUMBER
echo -ne $PF9_OVN_BUILD_VERSION > $ROOT/ovn-deb-version.txt

sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION/g" $ROOT/debian/changelog
sed -i "s/__PF9_OVN_BUILD_VERSION__/$PF9_OVN_BUILD_VERSION/g" $ROOT/configure.ac

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
mkdir -p "$ROOT/pkgs"
cp -v "$ROOT"/*.deb "$ROOT/pkgs/"
cp -v ../*.deb "$ROOT/pkgs/"

cd $ROOT/pkgs/
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz