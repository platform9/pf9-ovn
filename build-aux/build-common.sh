# Common configuration and helpers for pf9 OVN/OVS builds.
# Source this file; do not execute directly.

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

OVS_BASE="3.6.2"
OVN_BASE="25.09.3"

# Cache tarball for a prebuilt OVS tree (see pf9_pack_ovs_cache / pf9_restore_ovs_cache).
# Consumers (build-debs.sh / build-rpms.sh) look for it under
# $TEAMCITY_ROOT/ovs-cache/ovs-build-<plat>.tar.gz -- a TeamCity artifact
# dependency (or the parallel orchestrator, build-parallel.sh) is expected to
# have dropped it there before the platform build runs.
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
    # NOTE: a cache-restored OVS tree has no .git (deliberately excluded when
    # packed -- see pf9_pack_ovs_cache below), so guard this or a cache hit
    # would make cleanup fail here every time. A from-source tree still goes
    # through the same git reset/clean as before.
    if [ -d .git ]; then
        git reset HEAD --hard
        git clean -fdx
    else
        rm -rf "$ROOT/ovs"
    fi
}

# ---------------------------------------------------------------------------
# Prebuilt OVS cache.
# OVS is rebuilt from scratch on every run. build-debs.sh / build-rpms.sh now
# try pf9_restore_ovs_cache before rebuilding, and call pf9_pack_ovs_cache
# right after a from-source build so the NEXT run can reuse it.
#
# Cache identity is checked on four axes: ROOT (absolute checkout path --
# libtool/config.status embed absolute paths, so a cache is only valid at the
# same ROOT), platform, OVS_BASE, and the OVS git submodule SHA recorded in
# the OVN superproject. Any mismatch is a safe fallback to a from-source
# build, never a false hit.
#
# Tarball layout (paths relative to $TEAMCITY_ROOT):
#   pf9-ovn/ovs/                          whole tree incl. _debian/ or rpm/
#                                         (ovs/.git excluded: a fresh
#                                         checkout has its own git metadata)
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

# pf9_restore_ovs_cache <plat> <expected_ovs_sha>
# Returns 0 (and replaces $ROOT/ovs + OVS packages with the cached ones) only
# if $TEAMCITY_ROOT/ovs-cache/ovs-build-<plat>.tar.gz exists and its
# ROOT/PLAT/OVS_BASE/OVS_SHA all match the current values; returns 1 with a
# reason otherwise, leaving $ROOT/ovs untouched so the caller can initialize
# the submodule and build from source.
#
# NOTE: designed to be used as `if pf9_restore_ovs_cache ...` -- bash disables
# `set -e` inside an if-condition, so every step here checks its own status.
pf9_restore_ovs_cache() {
    local plat="$1"
    local expected_ovs_sha="$2"
    local tarball="$TEAMCITY_ROOT/ovs-cache/ovs-build-${plat}.tar.gz"
    local tmp meta key val
    local c_root="" c_plat="" c_base="" c_sha="" c_built=""

    if [ ! -f "$tarball" ]; then
        echo "OVS cache: no tarball at $tarball -> building OVS from source"
        return 1
    fi

    if [ -z "$expected_ovs_sha" ]; then
        echo "OVS cache: cannot determine OVS gitlink from $ROOT"
        return 1
    fi

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
       || [ "$c_base" != "$OVS_BASE" ] || [ "$c_sha" != "$expected_ovs_sha" ]; then
        echo "OVS cache: metadata mismatch -> building OVS from source"
        echo "  ROOT     cached='$c_root' current='$ROOT'"
        echo "  PLAT     cached='$c_plat' current='$plat'"
        echo "  OVS_BASE cached='$c_base' current='$OVS_BASE'"
        echo "  OVS_SHA  cached='$c_sha' current='$expected_ovs_sha'"
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

    # Replace the uninitialized or absent submodule directory with the cached
    # source/build tree. The cache does not need Git metadata to build OVN.
    if ! { rm -rf "$ROOT/ovs" \
           && mv "$tmp/pf9-ovn/ovs" "$ROOT/ovs" \
           && { [ "$plat" = r10 ] || mv "$tmp"/pf9-ovn/*.deb "$ROOT"/; }; }; then
        echo "OVS cache: failed to move cached tree/packages into place"
        rm -rf "$ROOT/ovs" "$tmp"
        return 1
    fi
    rm -rf "$tmp"

    echo "OVS cache: HIT -> using prebuilt OVS tree from $tarball (built $c_built, sha $c_sha)"
    return 0
}
