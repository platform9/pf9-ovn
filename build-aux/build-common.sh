# Common configuration and helpers for pf9 OVN/OVS builds.
# Source this file; do not execute directly.

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

OVS_BASE="3.3.9"
OVN_BASE="24.03.9"

# Cache tarball for a prebuilt OVS tree (see pf9_pack_ovs_cache / pf9_restore_ovs_cache).
# Consumers (build-debs.sh / build-rpms.sh) look for it under
# $TEAMCITY_ROOT/ovs-cache/ovs-build-<plat>.tar.gz -- a TeamCity artifact
# dependency (or the parallel orchestrator, build-parallel.sh) is expected to
# have dropped it there before the platform build runs.
PF9_OVS_CACHE_META=".pf9-ovs-cache.meta"

# PF9_DEBUG_SYMBOLS (TeamCity parameter env.PF9_DEBUG_SYMBOLS, default true; set it to
# false to skip): the builds also keep the debug-symbol packages the toolchain already generates
# (-dbgsym .ddeb on Ubuntu, -debuginfo/-debugsource RPMs on Rocky), so perf/gdb can
# symbolize exactly this build. They go to debug/<os>-dbgsym or debug/<os>-debuginfo,
# next to pkgs/ rather than inside it, so Packages.tar.gz (the hostagent repo and
# container image input) is unchanged; they are packed into a separate debug.tar.gz
# build artifact (about 100 MB for u22 + u24 + r10).
PF9_DEBUG_DIR="$TEAMCITY_ROOT/debug"

pf9_debug_symbols_enabled() {
    case "${PF9_DEBUG_SYMBOLS:-true}" in
        false|FALSE|False|0|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

# pf9_reset_debug_symbols removes debug/, debug.tar.gz and stray -dbgsym packages left
# by an earlier build on this agent, so a build never publishes another build's symbols
# (they would not match its BuildIDs). build-parallel.sh gives each platform a fresh
# folder and clears the shared debug/ itself at job start. When the OS builds instead
# run as separate steps in one shared checkout, they add to debug/ in turn, so the reset
# runs once per build: the first step of a new BUILD_NUMBER clears and stamps debug/,
# and later steps of the same build see the stamp and keep what earlier steps collected.
# Without a BUILD_NUMBER (a local run) it always clears. It runs whether or not symbols
# are enabled, so a build with PF9_DEBUG_SYMBOLS=false cannot pick up a stale
# debug.tar.gz either.
pf9_reset_debug_symbols() {
    if [ -n "${BUILD_NUMBER:-}" ] && \
       [ "$(cat "$PF9_DEBUG_DIR/.build-number" 2>/dev/null)" = "$BUILD_NUMBER" ]; then
        return 0
    fi
    rm -rf "$PF9_DEBUG_DIR"
    rm -f "$TEAMCITY_ROOT/debug.tar.gz"
    # dpkg-buildpackage writes OVN's .ddeb files next to the checkout; an older build's
    # would otherwise be swept into this build's archive.
    rm -f "$TEAMCITY_ROOT"/*-dbgsym_*.ddeb "$ROOT"/*-dbgsym_*.ddeb
    mkdir -p "$PF9_DEBUG_DIR"
    printf '%s\n' "${BUILD_NUMBER:-}" > "$PF9_DEBUG_DIR/.build-number"
}

# pf9_pack_debug_symbols (re)creates $TEAMCITY_ROOT/debug.tar.gz from everything collected
# in debug/ so far. Each OS build calls it, so after the last one the archive holds all
# of them. build-parallel.sh sets PF9_DEBUG_PACK=0: it copies each platform's debug/
# back and packs once at the end.
pf9_pack_debug_symbols() {
    [ "${PF9_DEBUG_PACK:-1}" = 0 ] && return 0
    tar -czf "$TEAMCITY_ROOT/debug.tar.gz" -C "$TEAMCITY_ROOT" --exclude=.build-number debug
    ls -la "$TEAMCITY_ROOT/debug.tar.gz"
}

# Package version scheme (OVN and OVS, deb and rpm):
#
#     <epoch>:<OVN/OVS base>-<PF9_VERSION>-<TEAMCITY_BUILD_ID>-<OS>
#     e.g.  2:24.03.6-2026.9.0-1234567-u22   (deb)   2:24.03.6-2026.9.0.1234567.r10 (rpm)
#
# - Epoch 2 beats every package built under the old "1:<base>-pf9-<ver>-<build number>"
#   and static "1:<base>-pf9" schemes, so existing hosts upgrade.
# - The build counter is TeamCity's internal build id (%teamcity.build.id%, exported as
#   TEAMCITY_BUILD_ID), not the build number: the id is unique and increases across every
#   build configuration, branch and private build, so versions order by build time.
# - There is no "pf9" token in the package version. RPM Version/Release cannot contain
#   hyphens, so there the same fields are Version=<base>, Release=<PF9_VERSION>.<id>.<OS>.
#
# The *binary* version baked into configure.ac (ovn-appctl version, and through it the
# northd_internal_version in SB_Global) is NOT the package version. It keeps the
# ".pf9.<PF9_VERSION>.<id>" sub-version: ovn_version_base() in
# controller/ovn-controller.c strips ".pf9" up to the next "-" before comparing
# controller and northd versions (PCD-8825, 4fa1ef430), so builds that differ only in
# PF9 version/build id still match. Dropping ".pf9" from the binary version would make
# every controller/northd pair with different builds mismatch.
PF9_PKG_EPOCH=2

# pf9_set_build_id: sets PF9_BUILD_ID from TEAMCITY_BUILD_ID, failing the build when it is
# missing or not numeric (an unset id would silently produce a version that sorts lowest).
pf9_set_build_id() {
    if ! [[ "${TEAMCITY_BUILD_ID:-}" =~ ^[0-9]+$ ]]; then
        echo "FATAL: TEAMCITY_BUILD_ID must be set to the numeric TeamCity build id" \
             "(%teamcity.build.id%); got '${TEAMCITY_BUILD_ID:-}'. For a local build," \
             "export a number that is larger than the build id installed on the target." >&2
        exit 1
    fi
    PF9_BUILD_ID="$TEAMCITY_BUILD_ID"
}

pf9_git_setup() {
    git config --global --add safe.directory '*'
    git config --global url."https://github.com/".insteadOf "git@github.com:"
}

pf9_submodule_update() {
    git -C "$ROOT" submodule update --init --recursive
}

pf9_patch_ovn_binary_version() {
    # Fail loudly if PF9_OVN_VERSION (pf9-version.rc) and OVN_BASE above have
    # silently drifted apart - e.g. a release bumped the OVN suffix in
    # PF9_OVN_VERSION without rebasing the OVN source actually checked into
    # this repo, or vice versa. PF9_OVN_VERSION looks like
    # "2026.9.0-v24.03.6"; the part after "-v" is expected to equal OVN_BASE
    # exactly.
    ovn_version_suffix="${PF9_OVN_VERSION#*-v}"
    if [ "$ovn_version_suffix" = "$PF9_OVN_VERSION" ] || \
       [ "$ovn_version_suffix" != "$OVN_BASE" ]; then
        echo "FATAL: PF9_OVN_VERSION ('${PF9_OVN_VERSION}') does not encode" \
             "OVN_BASE ('${OVN_BASE}') - pf9-version.rc and build-common.sh" \
             "have drifted apart. Update one to match the other." >&2
        exit 1
    fi

    # Dots throughout, no epoch, no OS suffix — identical on all platforms.
    # configure.ac carries this into OVN_PACKAGE_VERSION and thus ovn-appctl version.
    # Keeps ".pf9." (see the version scheme comment above) and uses the same build id as the package.
    PF9_OVN_BINARY_VERSION=${OVN_BASE}.pf9.${PF9_VERSION}.${PF9_BUILD_ID}
    sed -i "s/__PF9_OVN_BUILD_VERSION__/${PF9_OVN_BINARY_VERSION}/g" "$ROOT/configure.ac"
}

# --- Source commit stamp ------------------------------------------------------------
# Every OVN and OVS package records the git commit it was built from, so an installed
# build can be traced back to its source:
#   deb  control field   Pf9-Source-Sha: <sha>        (dpkg-deb -f <deb> Pf9-Source-Sha)
#   rpm  provide         pf9-source-sha(<sha>)        (rpm -q --provides <pkg>)
# The OVN sha is this repo's HEAD; the OVS sha is the commit the ovs submodule points at.

# pf9_stamp_deb_rules <debian/rules> <sha>: adds a dh_gencontrol override that writes the
# field into every binary package of that source tree. Used for OVS, a submodule this
# build does not edit in the repo (it patches its changelog and configure.ac the same
# way); OVN's own debian/rules stamps itself from PF9_OVN_SHA.
pf9_stamp_deb_rules() {
    local rules="$1" sha="$2"
    if grep -q '^override_dh_gencontrol:' "$rules"; then
        echo "FATAL: $rules already overrides dh_gencontrol; stamp it there instead" >&2
        exit 1
    fi
    printf '\noverride_dh_gencontrol:\n\tdh_gencontrol -- -DPf9-Source-Sha=%s\n' "$sha" >> "$rules"
}

# pf9_stamp_rpm_spec <spec> <sha>: adds "Provides: pf9-source-sha(<sha>)" to every package
# in the spec: after each Summary:, which every package and subpackage has exactly once.
pf9_stamp_rpm_spec() {
    local spec="$1" sha="$2" summaries provides
    sed -i "/^Summary:/a Provides: pf9-source-sha(${sha})" "$spec"
    summaries=$(grep -c '^Summary:' "$spec")
    provides=$(grep -c "^Provides: pf9-source-sha(${sha})\$" "$spec")
    if [ "$summaries" -lt 1 ] || [ "$summaries" != "$provides" ]; then
        echo "FATAL: could not stamp $spec ($summaries Summary lines, $provides stamps)" >&2
        exit 1
    fi
}

# pf9_verify_deb_stamp <sha> <deb>...: fails the build unless every deb carries the sha.
pf9_verify_deb_stamp() {
    local sha="$1" deb got
    shift
    for deb in "$@"; do
        got=$(dpkg-deb -f "$deb" Pf9-Source-Sha)
        if [ "$got" != "$sha" ]; then
            echo "FATAL: $(basename "$deb") Pf9-Source-Sha='$got', expected '$sha'" >&2
            exit 1
        fi
    done
}

# pf9_verify_rpm_stamp <sha> <rpm>...: fails the build unless every rpm provides the sha.
pf9_verify_rpm_stamp() {
    local sha="$1" rpm
    shift
    for rpm in "$@"; do
        if ! rpm -qp --provides "$rpm" | grep -qxF "pf9-source-sha(${sha})"; then
            echo "FATAL: $(basename "$rpm") does not provide pf9-source-sha(${sha})" >&2
            exit 1
        fi
    done
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
    if [ -e .git ]; then
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
        echo "OVS_PKG_VERSION=$PF9_OVS_PKG_VERSION"
        echo "OVS_SHA=$(git -C "$ROOT/ovs" rev-parse HEAD)"
        echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$meta"
    cat "$meta"

    rm -f "$tarball"
    case "$plat" in
        u22|u24)
            # Globs must match: a missing package means the OVS build did not
            # produce what build-debs.sh dpkg -i's, and tar will fail (set -e).
            # The OVS -dbgsym .ddeb files ride along (when the build made them), so a
            # cache hit can still publish OVS debug symbols.
            ( cd "$TEAMCITY_ROOT" && tar -czf "$tarball" \
                --exclude='pf9-ovn/ovs/.git' \
                pf9-ovn/ovs \
                pf9-ovn/openvswitch-*.deb pf9-ovn/python3-openvswitch_*.deb \
                $(cd "$TEAMCITY_ROOT" && ls pf9-ovn/*-dbgsym_*.ddeb 2>/dev/null) )
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
# ROOT/PLAT/OVS_BASE/OVS_SHA/OVS_PKG_VERSION all match the current values (the
# OVS package version carries the build id, so a cache from another build never matches); returns 1 with a
# reason otherwise, leaving $ROOT/ovs untouched so the caller can initialize
# the submodule and build from source.
#
# NOTE: designed to be used as `if pf9_restore_ovs_cache ...` -- bash disables
# `set -e` inside an if-condition, so every step here checks its own status.
pf9_restore_ovs_cache() {
    if [ $SKIP_OVS_CACHE -eq 1 ]; then
        echo "OVS cache: SKIP_OVS_CACHE=1 -> building OVS from source"
        return 1
    fi

    local plat="$1"
    local expected_ovs_sha="$2"
    local tarball="$TEAMCITY_ROOT/ovs-cache/ovs-build-${plat}.tar.gz"
    local tmp meta key val
    local c_root="" c_plat="" c_base="" c_sha="" c_built="" c_pkgver=""

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
            OVS_PKG_VERSION) c_pkgver="$val" ;;
            OVS_SHA)  c_sha="$val" ;;
            BUILT_AT) c_built="$val" ;;
        esac
    done < "$meta"

    if [ "$c_root" != "$ROOT" ] || [ "$c_plat" != "$plat" ] \
       || [ "$c_base" != "$OVS_BASE" ] || [ "$c_sha" != "$expected_ovs_sha" ] \
       || [ "$c_pkgver" != "$PF9_OVS_PKG_VERSION" ]; then
        echo "OVS cache: metadata mismatch -> building OVS from source"
        echo "  ROOT     cached='$c_root' current='$ROOT'"
        echo "  PLAT     cached='$c_plat' current='$plat'"
        echo "  OVS_BASE cached='$c_base' current='$OVS_BASE'"
        echo "  OVS_SHA  cached='$c_sha' current='$expected_ovs_sha'"
        echo "  OVS_PKG_VERSION cached='$c_pkgver' current='$PF9_OVS_PKG_VERSION'"
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
            # A cache packed before it carried the OVS .ddeb files would make this
            # build publish OVN symbols only. Rebuild once; the new cache has them.
            if pf9_debug_symbols_enabled && ! ls "$tmp"/pf9-ovn/*-dbgsym_*.ddeb >/dev/null 2>&1; then
                echo "OVS cache: tarball has no OVS -dbgsym .ddeb files and debug symbols are on -> building OVS from source"
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
           && { [ "$plat" = r10 ] || mv "$tmp"/pf9-ovn/*.deb "$ROOT"/; } \
           && { ! ls "$tmp"/pf9-ovn/*.ddeb >/dev/null 2>&1 || mv "$tmp"/pf9-ovn/*.ddeb "$ROOT"/; }; }; then
        echo "OVS cache: failed to move cached tree/packages into place"
        rm -rf "$ROOT/ovs" "$tmp"
        return 1
    fi
    rm -rf "$tmp"

    echo "OVS cache: HIT -> using prebuilt OVS tree from $tarball (built $c_built, sha $c_sha)"
    return 0
}