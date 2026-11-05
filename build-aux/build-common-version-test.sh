#!/bin/bash
# Regression test for build-common.sh's pf9_patch_ovn_binary_version()
# catching drift between pf9-version.rc's PF9_OVN_VERSION and this repo's
# own OVN_BASE constant. Before this check, bumping one without the other
# (e.g. a release label bump that forgot to rebase the vendored OVN
# source) was silent - the build just used whatever OVN_BASE already said.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_COMMON="$SCRIPT_DIR/build-common.sh"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
ROOT="$WORKDIR/pf9-ovn"
mkdir -p "$ROOT"
printf '__PF9_OVN_BUILD_VERSION__\n' > "$ROOT/configure.ac"

run_patch() {
    local pf9_ovn_version="$1"
    (
        cd "$WORKDIR"
        ROOT="$ROOT"
        . "$BUILD_COMMON"
        PF9_OVN_VERSION="$pf9_ovn_version"
        PF9_VERSION="2026.9.0"
        BUILD_NUMBER="42"
        TEAMCITY_BUILD_ID="7654321"
        pf9_set_build_id
        pf9_patch_ovn_binary_version
    )
}

# --- Part 1: matching versions build cleanly ---
# OVN_BASE in build-common.sh is currently 24.03.6 - keep this in sync with
# it; a failure here on an otherwise-untouched checkout most likely means
# someone bumped OVN_BASE without updating this test (or vice versa).
if ! run_patch "2026.9.0-v24.03.6" > "$WORKDIR/out.txt" 2>&1; then
    echo "FAIL: pf9_patch_ovn_binary_version rejected a PF9_OVN_VERSION" \
         "that should match the current OVN_BASE. Output:" >&2
    cat "$WORKDIR/out.txt" >&2
    exit 1
fi
echo "PASS: matching PF9_OVN_VERSION/OVN_BASE builds without error."

# --- Part 2: drifted versions fail loudly instead of silently building ---
if run_patch "2026.9.0-v99.99.99" > "$WORKDIR/out.txt" 2>&1; then
    echo "FAIL: pf9_patch_ovn_binary_version accepted a PF9_OVN_VERSION" \
         "whose OVN suffix doesn't match OVN_BASE at all - drift between" \
         "pf9-version.rc and build-common.sh would go unnoticed." >&2
    exit 1
fi
if ! grep -q "FATAL.*drifted apart" "$WORKDIR/out.txt"; then
    echo "FAIL: build failed as expected, but without the clear drift" \
         "message. Output:" >&2
    cat "$WORKDIR/out.txt" >&2
    exit 1
fi
echo "PASS: a mismatched PF9_OVN_VERSION/OVN_BASE fails the build loudly."

# --- Part 3: malformed PF9_OVN_VERSION (missing "-v<version>" suffix) also caught ---
if run_patch "2026.9.0" > "$WORKDIR/out.txt" 2>&1; then
    echo "FAIL: pf9_patch_ovn_binary_version accepted a PF9_OVN_VERSION with" \
         "no -v<version> suffix at all." >&2
    exit 1
fi
echo "PASS: a PF9_OVN_VERSION missing its -v<version> suffix is also caught."

# --- Part 4: the northd version match is unaffected by the package version scheme ---
# check_northd_version() strips ".pf9" up to the next "-" (ovn_version_base() in
# controller/ovn-controller.c, PCD-8825 / 4fa1ef430) so controller and northd built
# with different PF9 versions / build ids still match. That only works if the binary
# version baked into configure.ac still has ".pf9." in it - even though the package
# version (epoch 2, no "pf9") does not - and uses the TeamCity build id, not the number.
if ! run_patch "2026.9.0-v24.03.6" > "$WORKDIR/out.txt" 2>&1; then
    cat "$WORKDIR/out.txt" >&2; exit 1
fi
binver=$(cat "$ROOT/configure.ac")
if [ "$binver" != "24.03.6.pf9.2026.9.0.7654321" ]; then
    echo "FAIL: binary version is '$binver', expected 24.03.6.pf9.2026.9.0.7654321" \
         "(must keep .pf9. for ovn_version_base() and use the build id, not BUILD_NUMBER=42)." >&2
    exit 1
fi
# Same transformation as ovn_version_base(), applied to an internal version string
# "<binary version>-<ovs lib version>-<db schema>".
strip_pf9() { printf '%s\n' "$1" | sed 's/\.pf9[^-]*//'; }
a=$(strip_pf9 "${binver}-20.33.0-76.8")
b=$(strip_pf9 "24.03.6.pf9.2026.4.0.385-20.33.0-76.8")   # older controller, build number
c=$(strip_pf9 "24.03.6-20.33.0-76.8")                    # northd without a pf9 marker
if [ "$a" != "24.03.6-20.33.0-76.8" ] || [ "$a" != "$b" ] || [ "$a" != "$c" ]; then
    echo "FAIL: controller/northd versions no longer reduce to the same base: '$a' '$b' '$c'" >&2
    exit 1
fi
echo "PASS: binary version keeps .pf9. and reduces to the same northd match base."

# --- Part 5: build id is mandatory and numeric ---
for bad in "" "abc" "12 3"; do
    if ( cd "$WORKDIR"; ROOT="$ROOT"; . "$BUILD_COMMON"; TEAMCITY_BUILD_ID="$bad"; pf9_set_build_id ) > "$WORKDIR/out.txt" 2>&1; then
        echo "FAIL: pf9_set_build_id accepted TEAMCITY_BUILD_ID='$bad'" >&2
        exit 1
    fi
done
echo "PASS: a missing or non-numeric TEAMCITY_BUILD_ID fails the build."

# --- Part 6: package versions sort above the old schemes and order by build id ---
if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "2:24.03.6-2026.9.0-100-u22" gt "1:24.03.6-pf9-2026.9.0-999999+u22" \
        && dpkg --compare-versions "2:3.3.6-2026.9.0-100-u22" gt "1:3.3.6-pf9+u22" \
        && dpkg --compare-versions "2:24.03.6-2026.9.0-101-u22" gt "2:24.03.6-2026.9.0-100-u22" \
        && dpkg --compare-versions "2:24.03.6-2026.9.0-100-u24" gt "2:24.03.6-2026.9.0-100-u22" \
        && dpkg --compare-versions "2:24.03.6-2026.9.0-100-u22" ge "2:24.03.6-2026.9.0-100" \
        && dpkg --compare-versions "2:24.03.6-2026.9.0-1000-u22" gt "2:24.03.6-2026.9.0-999-u22" \
        || { echo "FAIL: deb version ordering is wrong" >&2; exit 1; }
    echo "PASS: deb versions order above the old schemes and by build id."
else
    echo "SKIP: dpkg not available, deb version ordering not checked."
fi
