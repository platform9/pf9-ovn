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
        PF9_OVN_SHA="${TEST_SHA:-0123456789abcdef0123456789abcdef01234567}"
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

# --- Part 4: binary version is derived from the commit SHA only ---
# No build number and no PF9_VERSION: a rebuild of the same commit must yield
# the identical string so ovn-controller and ovn-northd keep matching
# (ovn-match-northd-version) when pf9-apt skips an unchanged package.
printf '__PF9_OVN_BUILD_VERSION__\n' > "$ROOT/configure.ac"
run_patch "2026.9.0-v24.03.6" >/dev/null 2>&1
want="24.03.6.pf9.0123456789ab"
if [ "$(cat "$ROOT/configure.ac")" != "$want" ]; then
    echo "FAIL: binary version is '$(cat "$ROOT/configure.ac")', expected '$want'" >&2
    exit 1
fi
printf '__PF9_OVN_BUILD_VERSION__\n' > "$ROOT/configure.ac"
(cd "$WORKDIR"; ROOT="$ROOT"; . "$BUILD_COMMON"; PF9_OVN_VERSION="2026.9.0-v24.03.6"; PF9_VERSION="2027.1.0"; BUILD_NUMBER="999"; \
    PF9_OVN_SHA="0123456789abcdef0123456789abcdef01234567"; pf9_patch_ovn_binary_version) >/dev/null 2>&1
if [ "$(cat "$ROOT/configure.ac")" != "$want" ]; then
    echo "FAIL: binary version changed with PF9_VERSION/BUILD_NUMBER: '$(cat "$ROOT/configure.ac")'" >&2
    exit 1
fi
echo "PASS: binary version depends on the commit SHA only."
