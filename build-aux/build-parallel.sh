
set -e
set -u
set -o pipefail
 
TEAMCITY_ROOT="$(pwd)"
ROOT="$TEAMCITY_ROOT/pf9-ovn"
WORK_DIR="$TEAMCITY_ROOT/build"
LOG_DIR="$TEAMCITY_ROOT/build-logs"
 
: "${BUILD_NUMBER:?BUILD_NUMBER must be set (TeamCity provides this automatically)}"

CONTAINER_MOUNT=/build
 
declare -A IMAGE=(
    [u22]="quay.io/platform9/ubuntu:22.04"
    [u24]="quay.io/platform9/ubuntu:24.04"
    [r10]="quay.io/platform9/rockylinux:10.2"
    [k8s]="quay.io/platform9/golang:1.24.13-trixie"
)
declare -A SCRIPT=(
    [u22]="build-debs.sh"
    [u24]="build-debs.sh"
    [r10]="build-rpms.sh"
    [k8s]="build-ovn-k8s.sh"
)
declare -A SCRIPT_ARGS=(
    [u22]="u22"
    [u24]="u24"
    [r10]="r10"
    [k8s]=""
)
PLATFORMS=(u22 u24 r10 k8s)

rm -rf "$WORK_DIR" "$LOG_DIR"
mkdir -p "$WORK_DIR" "$LOG_DIR"
mkdir -p "$TEAMCITY_ROOT/pkgs" "$TEAMCITY_ROOT/ovs-cache"

echo "=== Preparing isolated per-platform checkouts ==="
for plat in "${PLATFORMS[@]}"; do
    dir="$WORK_DIR/$plat"
    mkdir -p "$dir"
    cp -a "$TEAMCITY_ROOT/pf9-version" "$dir/pf9-version"
    cp -a "$ROOT" "$dir/pf9-ovn"
    if [ "$plat" = "k8s" ]; then
        cp -a "$TEAMCITY_ROOT/pf9-ovn-kubernetes" "$dir/pf9-ovn-kubernetes"
    fi
    if [ -d "$TEAMCITY_ROOT/ovs-cache" ]; then
        cp -a "$TEAMCITY_ROOT/ovs-cache" "$dir/ovs-cache"
    fi

    # Make copied Git repositories independent from the original
    # TeamCity checkout/object store.
    for repo_root in "$dir/pf9-ovn" "$dir/pf9-ovn-kubernetes"; do
        [ -d "$repo_root" ] || continue

        # Handle the top-level repository.
        alternates="$(git -C "$repo_root" rev-parse --git-path objects/info/alternates)"

        if [ -f "$alternates" ]; then
            echo "Removing Git alternate from $repo_root"

            git -C "$repo_root" repack -a -d --no-local -q

            rm -f "$alternates"

            if [ -f "$alternates" ]; then
                echo "ERROR: failed to remove Git alternates from $repo_root"
                exit 1
            fi
        fi

        # Handle all initialized submodules recursively.
        git -C "$repo_root" submodule foreach --recursive '
            alternates="$(git rev-parse --git-path objects/info/alternates)"

            if [ -f "$alternates" ]; then
                echo "Removing Git alternate from $name"

                git repack -a -d --no-local -q

                rm -f "$alternates"

                if [ -f "$alternates" ]; then
                    echo "ERROR: failed to remove Git alternates from $name"
                    exit 1
                fi
            fi
        '
    done
done

run_platform_job() {
    local plat="$1" dir="$2" image="$3" script="$4" args="$5"
 
    docker run \
        --rm \
        --name "pf9-ovn-parallel-${plat}-${BUILD_NUMBER}" \
        -v "$dir":"$CONTAINER_MOUNT" \
        -w "$CONTAINER_MOUNT" \
        -e BUILD_NUMBER="$BUILD_NUMBER" \
        "$image" \
        bash -c "bash pf9-ovn/build-aux/$script $args"
 
    status=$?

    if [ -d "$dir/pkgs/$plat" ]; then
        rm -rf "$TEAMCITY_ROOT/pkgs/$plat"
        cp -a --no-preserve=ownership "$dir/pkgs/$plat" "$TEAMCITY_ROOT/pkgs/$plat"
    fi

    if [ "$plat" = "u22" ] || [ "$plat" = "u24" ]; then
        cp -a --no-preserve=ownership "$dir/ovn-deb-version.txt" "$TEAMCITY_ROOT/ovn-deb-version.txt" 2>/dev/null || true
    fi

    if [ "$plat" = "r10" ]; then
        cp -a --no-preserve=ownership "$dir/ovn-rpm-version.txt" "$TEAMCITY_ROOT/ovn-rpm-version.txt" 2>/dev/null || true
    fi

    if [ "$plat" != "k8s" ]; then
        if [ -f "$dir/ovs-build-${plat}.tar.gz" ]; then
            cp -a --no-preserve=ownership "$dir/ovs-build-${plat}.tar.gz" "$TEAMCITY_ROOT/ovs-cache/ovs-build-${plat}.tar.gz"
        elif [ -f "$dir/ovs-cache/ovs-build-${plat}.tar.gz" ]; then
            cp -a --no-preserve=ownership "$dir/ovs-cache/ovs-build-${plat}.tar.gz" "$TEAMCITY_ROOT/ovs-cache/ovs-build-${plat}.tar.gz"
        fi
    fi
    
    if [ "$plat" = "k8s" ]; then
        cp -a --no-preserve=ownership "$dir/pf9-ovn/container/." "$ROOT/container/" 2>/dev/null || true
    fi

    docker run --rm \
        -v "$dir:$CONTAINER_MOUNT" \
        -w "$CONTAINER_MOUNT" \
        "$image" \
        bash -c 'rm -rf -- ./* ./.??*'

    rm -rf "$dir"
    return "$status"
}

# Disable exit-on-error for the parallel build loop, so we can wait for all platforms and report which failed.
set +e

echo "=== Launching platform builds in parallel ==="
declare -A PID
for plat in "${PLATFORMS[@]}"; do
    dir="$WORK_DIR/$plat"
    image="${IMAGE[$plat]}"
    script="${SCRIPT[$plat]}"
    args="${SCRIPT_ARGS[$plat]}"
    log="$LOG_DIR/$plat.log"
 
    if [ ! -f "$dir/pf9-ovn/build-aux/$script" ]; then
        echo "  $plat: build-aux/$script not found in this checkout - cannot run" | tee "$log"
        ( exit 1 ) &
        PID[$plat]=$!
        continue
    fi
 
    ( run_platform_job "$plat" "$dir" "$image" "$script" "$args" ) > "$log" 2>&1 &
    PID[$plat]=$!
    echo "  launched $plat (pid ${PID[$plat]}, log: $log)"
done
 
echo "=== Waiting for all platform builds ==="
FAILED=()
for plat in "${PLATFORMS[@]}"; do
    if wait "${PID[$plat]}"; then
        echo "  $plat: SUCCESS"
    else
        echo "  $plat: FAILED (see $LOG_DIR/$plat.log)"
        FAILED+=("$plat")
    fi
done

rm -rf "$WORK_DIR"

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "=== FAILED platforms: ${FAILED[*]} - skipping final container build/publish ==="
    echo "Partial pkgs/ and ovs-cache/ have still been collected above for diagnostics"
    echo "and will still be published (TeamCity: 'Publish artifacts: even if build fails')."
    exit 1
fi

exit 0
