#!/bin/bash
set -euo pipefail

# On macOS, 'timeout' is provided by GNU coreutils as 'gtimeout'.
# Fall back to gtimeout if timeout is not in PATH.
if ! command -v timeout >/dev/null 2>&1; then
    if command -v gtimeout >/dev/null 2>&1; then
        timeout() { gtimeout "$@"; }
    else
        echo "ERROR: neither 'timeout' nor 'gtimeout' found. Install GNU coreutils (brew install coreutils)." >&2
        exit 1
    fi
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Determine the pf9-ovn root (parent of scripts/upgrade/tests).
# Works whether or not this is a git repo.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PF9OVN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WATCHDOG="$PF9OVN_ROOT/container/flow-watchdog.sh"

# Test 1: watchdog waits for snapshot file before starting (blocks until file exists)
test_waits_for_snapshot() {
    DIR=$(mktemp -d)
    # No snapshot file — watchdog should block and timeout
    timeout 2 env \
        SNAPSHOT_DIR="$DIR" \
        OVS_OFCTL="echo" \
        bash "$WATCHDOG" 2>/dev/null && fail "should have timed out waiting for snapshot" || pass "waits for snapshot before starting"
    rm -rf "$DIR"
}

# Test 2: watchdog loops when flow count is healthy (never drops)
test_loops_when_healthy() {
    DIR=$(mktemp -d)
    echo "cookie=0x0" > "$DIR/br-int.flows"
    echo "group_id=1" > "$DIR/br-int.groups"

    # Mock ovs-ofctl: always returns 500 flows (healthy)
    cat > "$DIR/mock_ovs" <<'MOCK'
#!/bin/sh
if [ "$1" = "dump-flows" ]; then
    i=0; while [ $i -lt 500 ]; do echo " cookie=0x0 actions=output:1"; i=$((i+1)); done
fi
MOCK
    chmod +x "$DIR/mock_ovs"

    # With healthy count, RESTORED never becomes 1, so watchdog never exits
    timeout 1 env \
        SNAPSHOT_DIR="$DIR" \
        OVS_OFCTL="$DIR/mock_ovs" \
        POLL_INTERVAL_SEC=0.01 \
        bash "$WATCHDOG" 2>/dev/null && fail "should still be running" || pass "keeps running when flow table healthy"
    rm -rf "$DIR"
}

# Test 3: watchdog calls add-flows when flow count drops below threshold
test_restores_on_clear() {
    DIR=$(mktemp -d)
    echo "cookie=0x0, table=0 actions=output:1" > "$DIR/br-int.flows"
    echo "group_id=1,type=select" > "$DIR/br-int.groups"
    RESTORE_LOG="/tmp/watchdog_restore_test_$$.log"
    rm -f "$RESTORE_LOG"

    # Mock ovs-ofctl: dump-flows returns 0 flows (cleared); add-flows logs to file
    cat > "$DIR/mock_ovs" <<MOCK
#!/bin/sh
if [ "\$1" = "dump-flows" ]; then
    : # no output = 0 flows
elif [ "\$1" = "add-flows" ]; then
    echo "add-flows called \$3" >> $RESTORE_LOG
elif [ "\$1" = "add-groups" ]; then
    echo "add-groups called" >> $RESTORE_LOG
fi
MOCK
    chmod +x "$DIR/mock_ovs"

    timeout 2 env \
        SNAPSHOT_DIR="$DIR" \
        OVS_OFCTL="$DIR/mock_ovs" \
        POLL_INTERVAL_SEC=0.01 \
        bash "$WATCHDOG" 2>/dev/null || true

    if grep -q "add-flows" "$RESTORE_LOG" 2>/dev/null; then
        pass "restores snapshot when flow table cleared"
    else
        fail "did not call add-flows when flow table cleared"
    fi
    rm -f "$RESTORE_LOG"
    rm -rf "$DIR"
}

test_waits_for_snapshot
test_loops_when_healthy
test_restores_on_clear

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
