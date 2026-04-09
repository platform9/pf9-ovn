# Common configuration and helpers for pf9 OVN/OVS builds.
# Source this file; do not execute directly.

TEAMCITY_ROOT="$(pwd)"
ROOT="$(pwd)/pf9-ovn"

OVS_BASE="3.3.6"
OVN_BASE="24.03.6"

pf9_git_setup() {
    git config --global --add safe.directory '*'
    git config --global url."https://github.com/".insteadOf "git@github.com:"
}

pf9_submodule_update() {
    git -C "$ROOT" submodule update --init --recursive
}

pf9_build_reset() {
    cd "$ROOT"
    git reset HEAD --hard
    git clean -fdx

    cd "$ROOT/ovs"
    git reset HEAD --hard
    git clean -fdx
}
