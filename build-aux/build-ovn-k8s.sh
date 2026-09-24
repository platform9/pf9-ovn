
set -e

OVN_K8s=$(pwd)/pf9-ovn-kubernetes
OVN=$(pwd)/pf9-ovn

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git make

cd $OVN_K8s
git config --global --add safe.directory '*'
git checkout v1.1.0
cd go-controller
make clean
make
cp -r _output/go/bin/* "$OVN/container"