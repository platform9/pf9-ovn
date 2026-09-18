# Common configuration and helpers for pf9 OVN/OVS builds.
# Source this file; do not execute directly.

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

OVS_BASE="3.3.6"
OVN_BASE="24.03.6"

# Cache tarball for a prebuilt OVS tree (see pf9_pack_ovs_cache / pf9_restore_ovs_cache).
# Producer (build-ovs.sh) writes $TEAMCITY_ROOT/ovs-build-<plat>.tar.gz;
# consumers (build-debs.sh / build-rpms.sh) look for it under
# $TEAMCITY_ROOT/ovs-cache/ (TC artifact dependency drops it there).
PF9_OVS_CACHE_META=".pf9-ovs-cache.meta"

pf9_git_setup() {
    git config --global --add safe.directory '*'
    git config --global url."https://github.com/".insteadOf "git@github.com:"
}

pf9_submodule_update() {
    git -C "$ROOT" submodule update --init --recursive
}

pf9_patch_ovn_binary_version() {
    # Dots throughout, no epoch, no OS suffix — identical on all platforms.
    # configure.ac carries this into OVN_PACKAGE_VERSION and thus ovn-appctl version.
    PF9_OVN_BINARY_VERSION=${OVN_BASE}.pf9.${PF9_VERSION}.${BUILD_NUMBER}
    sed -i "s/__PF9_OVN_BUILD_VERSION__/${PF9_OVN_BINARY_VERSION}/g" "$ROOT/configure.ac"
}

pf9_build_reset() {
    cd "$ROOT"
    git reset HEAD --hard
    git clean -fdx

    cd "$ROOT/ovs"
    git reset HEAD --hard
    git clean -fdx
}

# ---------------------------------------------------------------------------
# Build dependencies (one list per package flavour, shared by build-debs.sh,
# build-rpms.sh and build-ovs.sh so the OVS cache producer and its consumers
# can never drift apart).
# ---------------------------------------------------------------------------

pf9_install_build_deps_deb() {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      fakeroot build-essential autoconf automake bzip2 debhelper devscripts dpkg-dev \
      debhelper-compat dh-exec dh-python dh-sequence-python3 dh-sequence-sphinxdoc \
      graphviz iproute2 libcap-ng-dev libnuma-dev libpcap-dev libssl-dev libtool \
      libunbound-dev openssl pkg-config procps python3-all-dev python3-setuptools \
      python3-sortedcontainers python3-sphinx libjson-c-dev libevent-dev \
      libsystemd-dev python3 python3-pip curl python3-twisted python3-zope.interface \
      libunwind-dev git strongswan kmod uuid-runtime python3-netifaces
}

pf9_install_build_deps_rpm() {
    # Enable EPEL and CRB repos for additional packages
    dnf install -y epel-release
    dnf config-manager --set-enabled crb

    # redhat-rpm-config is listed explicitly (not just via rpm-build's
    # system-rpm-config dependency) so %{?_smp_mflags} in the OVS/OVN specs
    # is guaranteed to expand to -j<ncpu>; without it both %build steps
    # silently fall back to a serial make.
    dnf install -y \
      rpm-build rpmdevtools redhat-rpm-config autoconf automake libtool gcc gcc-c++ \
      openssl openssl-devel python3-devel systemd-units checkpolicy \
      selinux-policy-devel groff graphviz libcap-ng-devel \
      unbound unbound-devel procps-ng bzip2 git createrepo_c \
      libpcap-devel numactl-devel python3-sphinx python3-sortedcontainers \
      libevent-devel json-c-devel libunwind-devel \
      desktop-file-utils libbpf-devel libxdp-devel
}

# ---------------------------------------------------------------------------
# OVS version edits + build. Static version (no build counter): only bump
# manually when OVS code changes. These edits mutate the ovs/ submodule tree,
# so they must run exactly once per tree: on a fresh build, or in the cache
# producer -- never on a tree restored by pf9_restore_ovs_cache.
# ---------------------------------------------------------------------------

# Prints the static OVS package version for a platform.
#   deb: 1:3.3.6-pf9+u22   (epoch 1 beats upstream; no build counter so
#        existing CI-versioned installs 1:3.3.x-pf9-YYYY.M.P-NNN stay >=)
#   rpm: 3.3.6.pf9         (RPM Version field does not allow hyphens)
pf9_ovs_build_version() {
    case "$1" in
        u22|u24) printf '%s' "1:${OVS_BASE}-pf9+$1" ;;
        r10)     printf '%s' "${OVS_BASE}.pf9" ;;
        *) echo "pf9_ovs_build_version: unknown platform '$1'" >&2; return 1 ;;
    esac
}

# Requires PF9_OVS_BUILD_VERSION (deb form) to be set by the caller.
pf9_patch_ovs_version_deb() {
    # Update OVS Changelog
    sed -i "s/${OVS_BASE}-1/$PF9_OVS_BUILD_VERSION/g" "$ROOT/ovs/debian/changelog"

    # Python setuptools sanitization (PEP 440)
    # Strip epoch and +UBUNTU_VERSION before converting to dot-notation, then re-add + for local segment
    PF9_OVS_PYTHON_VERSION=$(echo "$PF9_OVS_BUILD_VERSION" | sed "s/^1://; s/+[^-]*$//; s/-/./g; s/${OVS_BASE}./${OVS_BASE}+/")
    sed -i "s/${OVS_BASE}/$PF9_OVS_PYTHON_VERSION/g" "$ROOT/ovs/configure.ac"
}

# Requires PF9_OVS_BUILD_VERSION (rpm form) to be set by the caller.
pf9_patch_ovs_version_rpm() {
    # Update OVS configure.ac
    sed -i "s/${OVS_BASE}/${PF9_OVS_BUILD_VERSION}/g" "$ROOT/ovs/configure.ac"

    # Inject Epoch: 1 into the OVS spec on the fly (submodule is not tracked)
    sed -i 's/^Version: @VERSION@/Epoch: 1\nVersion: @VERSION@/' "$ROOT/ovs/rhel/openvswitch-fedora.spec.in"
}

pf9_build_ovs_deb() {
    # Note: Artifacts from make debian-deb usually land in the directory ABOVE the build dir.
    # Since we build in $ROOT/ovs, debs land in $ROOT.
    ( cd "$ROOT/ovs" && ./boot.sh )
    ( cd "$ROOT/ovs" && ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --enable-ssl --enable-shared )
    ( cd "$ROOT/ovs" && make debian && make debian-deb)
}

pf9_build_ovs_rpm() {
    ( cd "$ROOT/ovs" && ./boot.sh )
    ( cd "$ROOT/ovs" && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --enable-ssl )
    ( cd "$ROOT/ovs" && make rpm-fedora RPMBUILD_OPT="--without check" )
}

# ---------------------------------------------------------------------------
# Prebuilt OVS cache.
#
# Build 5132375: per platform ~18 min, of which OVS boot/configure/dist 2.2 +
# make -j8 3.6 + install/dh/debs 1.0 = ~7 min is spent rebuilding an OVS
# whose version is static (3.3.6, no build counter). OVN links against the
# OVS *build tree* (--with-ovs-build=ovs/_debian on deb, --with-ovs-source=ovs
# on rpm) and needs the OVS packages installed, so the cache unit is the whole
# post-build ovs/ tree plus the produced OVS packages. libtool/config.status
# embed absolute paths, so a cache is only valid at the same $ROOT.
#
# Tarball layout (paths relative to $TEAMCITY_ROOT):
#   pf9-ovn/ovs/                          whole tree incl. _debian/ or rpm/
#                                         (ovs/.git excluded: the live
#                                         checkout keeps its own git metadata)
#   pf9-ovn/ovs/.pf9-ovs-cache.meta       ROOT= PLAT= OVS_BASE= OVS_SHA= BUILT_AT=
#   pf9-ovn/openvswitch-*.deb
#   pf9-ovn/python3-openvswitch_*.deb     deb only (make debian-deb drops them
#                                         in $ROOT, the parent of ovs/)
#   (rpm packages live under ovs/rpm/rpmbuild/RPMS, i.e. inside the tree)
# ---------------------------------------------------------------------------

# pf9_pack_ovs_cache <plat>
# Run right after a fresh OVS build, BEFORE pf9_build_reset (which wipes it).
pf9_pack_ovs_cache() {
    local plat="$1"
    local tarball="$TEAMCITY_ROOT/ovs-build-${plat}.tar.gz"
    local meta="$ROOT/ovs/$PF9_OVS_CACHE_META"

    {
        echo "ROOT=$ROOT"
        echo "PLAT=$plat"
        echo "OVS_BASE=$OVS_BASE"
        echo "OVS_SHA=$(git -C "$ROOT/ovs" rev-parse HEAD)"
        echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$meta"
    cat "$meta"

    rm -f "$tarball"
    case "$plat" in
        u22|u24)
            # Globs must match: a missing package means the OVS build did not
            # produce what build-debs.sh dpkg -i's, and tar will fail (set -e).
            ( cd "$TEAMCITY_ROOT" && tar -czf "$tarball" \
                --exclude='pf9-ovn/ovs/.git' \
                pf9-ovn/ovs \
                pf9-ovn/openvswitch-*.deb pf9-ovn/python3-openvswitch_*.deb )
            ;;
        r10)
            test -d "$ROOT/ovs/rpm/rpmbuild/RPMS" || { echo "pf9_pack_ovs_cache: no RPMS dir under ovs/rpm"; return 1; }
            ( cd "$TEAMCITY_ROOT" && tar -czf "$tarball" \
                --exclude='pf9-ovn/ovs/.git' \
                pf9-ovn/ovs )
            ;;
        *)
            echo "pf9_pack_ovs_cache: unknown platform '$plat'"
            return 1
            ;;
    esac
    ls -lh "$tarball"
}

# pf9_restore_ovs_cache <plat>
# Call AFTER pf9_submodule_update. Returns 0 (and replaces $ROOT/ovs + OVS
# packages with the cached ones) only if $TEAMCITY_ROOT/ovs-cache/
# ovs-build-<plat>.tar.gz exists and its ROOT/PLAT/OVS_BASE/OVS_SHA all match
# the current values; returns 1 with a reason otherwise, leaving the fresh
# submodule checkout untouched so the caller can build from source.
#
# NOTE: designed to be used as `if pf9_restore_ovs_cache ...` -- bash disables
# `set -e` inside an if-condition, so every step here checks its own status.
pf9_restore_ovs_cache() {
    local plat="$1"
    local tarball="$TEAMCITY_ROOT/ovs-cache/ovs-build-${plat}.tar.gz"
    local tmp meta key val
    local c_root="" c_plat="" c_base="" c_sha="" c_built=""
    local want_sha

    if [ ! -f "$tarball" ]; then
        echo "OVS cache: no tarball at $tarball -> building OVS from source"
        return 1
    fi

    want_sha="$(git -C "$ROOT/ovs" rev-parse HEAD)" || {
        echo "OVS cache: cannot determine submodule HEAD in $ROOT/ovs"
        return 1
    }

    # Extract on the same filesystem as $ROOT so the final placement is a rename.
    tmp="$(mktemp -d "$TEAMCITY_ROOT/ovs-cache-extract.XXXXXX")" || {
        echo "OVS cache: mktemp failed"
        return 1
    }
    if ! tar -xzf "$tarball" -C "$tmp"; then
        echo "OVS cache: $tarball is corrupt (tar -x failed) -> building OVS from source"
        rm -rf "$tmp"
        return 1
    fi

    meta="$tmp/pf9-ovn/ovs/$PF9_OVS_CACHE_META"
    if [ ! -f "$meta" ]; then
        echo "OVS cache: $tarball has no $PF9_OVS_CACHE_META -> building OVS from source"
        rm -rf "$tmp"
        return 1
    fi
    while IFS='=' read -r key val; do
        case "$key" in
            ROOT)     c_root="$val" ;;
            PLAT)     c_plat="$val" ;;
            OVS_BASE) c_base="$val" ;;
            OVS_SHA)  c_sha="$val" ;;
            BUILT_AT) c_built="$val" ;;
        esac
    done < "$meta"

    if [ "$c_root" != "$ROOT" ] || [ "$c_plat" != "$plat" ] \
       || [ "$c_base" != "$OVS_BASE" ] || [ "$c_sha" != "$want_sha" ]; then
        echo "OVS cache: metadata mismatch -> building OVS from source"
        echo "  ROOT     cached='$c_root' current='$ROOT'"
        echo "  PLAT     cached='$c_plat' current='$plat'"
        echo "  OVS_BASE cached='$c_base' current='$OVS_BASE'"
        echo "  OVS_SHA  cached='$c_sha' current='$want_sha'"
        rm -rf "$tmp"
        return 1
    fi

    # Validate package payload before touching $ROOT/ovs, so every "return 1"
    # up to here leaves the fresh checkout intact for a from-source build.
    case "$plat" in
        u22|u24)
            if ! ls "$tmp"/pf9-ovn/openvswitch-*.deb "$tmp"/pf9-ovn/python3-openvswitch_*.deb >/dev/null 2>&1; then
                echo "OVS cache: tarball has no openvswitch-*.deb / python3-openvswitch_*.deb -> building OVS from source"
                rm -rf "$tmp"
                return 1
            fi
            ;;
        r10)
            if ! ls "$tmp"/pf9-ovn/ovs/rpm/rpmbuild/RPMS/*/*.rpm >/dev/null 2>&1; then
                echo "OVS cache: tarball has no ovs/rpm/rpmbuild/RPMS/*/*.rpm -> building OVS from source"
                rm -rf "$tmp"
                return 1
            fi
            ;;
    esac

    # Swap the fresh submodule checkout for the cached tree, keeping the live
    # checkout's .git (file or dir) so git -C ovs keeps working for
    # pf9_build_reset. Any failure past this point leaves ovs/ in an unknown
    # (possibly already version-patched) state, so re-create the pristine
    # submodule checkout before returning 1: the caller's from-source path
    # re-applies the version seds and must not see a half-patched tree.
    if ! { rm -rf "$tmp/pf9-ovn/ovs/.git" \
           && mv "$ROOT/ovs/.git" "$tmp/pf9-ovn/ovs/.git" \
           && rm -rf "$ROOT/ovs" \
           && mv "$tmp/pf9-ovn/ovs" "$ROOT/ovs" \
           && { [ "$plat" = r10 ] || mv "$tmp"/pf9-ovn/*.deb "$ROOT"/; }; }; then
        echo "OVS cache: failed to move cached tree/packages into place; re-checking out submodule"
        rm -rf "$ROOT/ovs" "$tmp"
        pf9_submodule_update || return 1
        return 1
    fi
    rm -rf "$tmp"

    echo "OVS cache: HIT -> using prebuilt OVS tree from $tarball (built $c_built, sha $c_sha)"
    return 0
}
