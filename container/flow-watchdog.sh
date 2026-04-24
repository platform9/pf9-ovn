#!/bin/sh
# Flow watchdog: safety net for ovn-controller restart flow gap.
# Restores a pre-captured OVS flow snapshot if br-int is cleared during restart.
# Primary protection is ovn-ofctrl-wait-before-clear + atomic bundle (ofctrl.c).
# This script is the fallback.

SNAPSHOT_DIR="${SNAPSHOT_DIR:-/flow-snapshots}"
FLOWS_FILE="$SNAPSHOT_DIR/br-int.flows"
GROUPS_FILE="$SNAPSHOT_DIR/br-int.groups"
THRESHOLD="${FLOW_THRESHOLD:-10}"
RECONCILED_THRESHOLD="${FLOW_RECONCILED_THRESHOLD:-200}"
POLL_INTERVAL="${POLL_INTERVAL_SEC:-0.05}"
OVS_OFCTL="${OVS_OFCTL:-ovs-ofctl}"

log() { logger -t ovn-flow-watchdog "$*" 2>/dev/null || echo "[ovn-flow-watchdog] $*" >&2; }

# Wait until a valid snapshot exists from the preStop hook of the previous pod.
log "waiting for flow snapshot at $FLOWS_FILE"
while [ ! -f "$FLOWS_FILE" ]; do sleep 1; done
log "snapshot found, starting monitor loop"

RESTORED=0

while true; do
    COUNT=$("$OVS_OFCTL" dump-flows br-int 2>/dev/null \
            | grep -vc "^NXST\|^OFPST\|^OFPT" 2>/dev/null || true)

    if [ "$COUNT" -lt "$THRESHOLD" ] && [ "$RESTORED" -eq 0 ]; then
        log "flow table cleared (count=$COUNT < threshold=$THRESHOLD), restoring snapshot"
        "$OVS_OFCTL" add-groups br-int "$GROUPS_FILE" 2>/dev/null || true
        "$OVS_OFCTL" add-flows  br-int "$FLOWS_FILE"  2>/dev/null || true
        RESTORED=1
        log "snapshot restored"
    elif [ "$COUNT" -gt "$RECONCILED_THRESHOLD" ] && [ "$RESTORED" -eq 1 ]; then
        log "reconciliation complete (count=$COUNT), watchdog retiring"
        exit 0
    fi

    sleep "$POLL_INTERVAL"
done
