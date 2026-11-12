
set -ex
TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"
source pf9-version/pf9-version.rc

if [ -f "$ROOT/build-aux/build-common.sh" ]; then
    source "$ROOT/build-aux/build-common.sh"
    export TAG="$PF9_VERSION-v$OVN_BASE-$BUILD_NUMBER"
else
    # for jan 2026.1 release backward compat
    export TAG=$PF9_OVN_VERSION-$BUILD_NUMBER
fi

echo "tag: $TAG"

# Quay repo
DOCKER_REPOSITORY="quay.io/platform9/pf9-ovn"
# Public ECR repo
ECR_PUBLIC_REPOSITORY="public.ecr.aws/platform9/pf9-ovn"

cp -r "$TEAMCITY_ROOT/pkgs/" "$ROOT/container"
# Debug symbols for the image (PCD-10646): only the packages container/Dockerfile
# installs, from this build's debug/ (build-common.sh). The folder must exist even when
# empty (PF9_DEBUG_SYMBOLS=false), because the Dockerfile bind-mounts it.
rm -rf "$ROOT/container/debug"
mkdir -p "$ROOT/container/debug/u24-dbgsym"
for p in ovn-central ovn-common openvswitch-common; do
  if ls "$TEAMCITY_ROOT"/debug/u24-dbgsym/${p}-dbgsym_*.ddeb >/dev/null 2>&1; then
    cp "$TEAMCITY_ROOT"/debug/u24-dbgsym/${p}-dbgsym_*.ddeb "$ROOT/container/debug/u24-dbgsym/"
  else
    echo "WARNING: no ${p}-dbgsym in debug/u24-dbgsym; the image will lack its symbols"
  fi
done
# Build using Quay tag
docker build --no-cache \
  -t "$DOCKER_REPOSITORY:$TAG" \
  -f "$ROOT/container/Dockerfile" \
  "$ROOT/container"
# Tag for public ECR
docker tag "$DOCKER_REPOSITORY:$TAG" "$ECR_PUBLIC_REPOSITORY:$TAG"
# Push to Quay and public ECR
docker push "$DOCKER_REPOSITORY:$TAG"
docker push "$ECR_PUBLIC_REPOSITORY:$TAG"
# Record tag as before
echo "$TAG" > "$TEAMCITY_ROOT/container-tag.txt"
cd "$TEAMCITY_ROOT"
tar -czf Packages.tar.gz pkgs