#!/bin/bash
# Regression test for debian/ovn-host.prerm's "remove" case: cleanup must
# still happen when ovn-controller is already stopped, not just when it's
# live to signal.
#
# Before this fix: prerm always called "ovn-ctl --no-monitor stop_controller",
# which bottoms out in ovn-lib.in's stop_ovn_daemon() finding no pidfile for
# an already-stopped controller and returning success immediately - the real
# cleanup (binding_cleanup()/chassis_cleanup() in controller/binding.c,
# controller/chassis.c) only runs as part of a *live* controller's own
# graceful non-restart exit, so it silently never happened. Any host where
# ovn-controller happened to already be down at removal time (crashed,
# manually stopped, boot without the service, Restart=on-failure exhausted)
# would leave its Chassis row, Chassis_Private row, and Port_Binding
# chassis/encap columns behind as permanent garbage in the southbound DB.
#
# This extracts the real "remove|deconfigure)" case body out of the real
# prerm script and runs it twice: once with a live controller (asserting
# the existing ovn-ctl path is taken, DB cleanup skipped), once with it
# already stopped (asserting the DB-level fallback runs instead).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRERM_SRC="$SCRIPT_DIR/debian/ovn-host.prerm"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"

# prerm hardcodes /usr/share/ovn/scripts/ovn-ctl rather than taking it as a
# parameter, so point that exact path at the fake instead of overriding via
# PATH alone (mirrors the same pattern in the ovs submodule's prerm test).
PRERM="$WORKDIR/prerm"
sed "s#/usr/share/ovn/scripts/ovn-ctl#$FAKEBIN/ovn-ctl#g" "$PRERM_SRC" > "$PRERM"
chmod +x "$PRERM"

write_fake() {
    local name="$1" body="$2" log="$3"
    cat > "$FAKEBIN/$name" <<EOF
#!/bin/bash
echo "$name \$*" >> "$log"
$body
EOF
    chmod +x "$FAKEBIN/$name"
}

run_prerm() {
    # $1: "active" or "inactive" - whether the fake systemctl reports
    # ovn-host as running. Returns the path to that run's call log.
    local controller_state="$1" log="$WORKDIR/calls-$1.log"
    : > "$log"

    write_fake systemctl "
case \"\$*\" in
    \"is-active --quiet ovn-host\") [ '$controller_state' = active ] ;;
    *) exit 0 ;;
esac" "$log"

    write_fake ovn-ctl 'exit 0' "$log"

    write_fake ovs-vsctl "
case \"\$*\" in
    'get Open_vSwitch . external_ids:ovn-remote') echo '\"tcp:127.0.0.1:6642\"' ;;
    'get Open_vSwitch . external_ids:system-id') echo '\"chassis-under-test\"' ;;
    *) exit 0 ;;
esac" "$log"

    write_fake ovn-sbctl "
case \"\$*\" in
    *'--if-exists get Chassis chassis-under-test _uuid'*) echo 'fake-chassis-uuid' ;;
    *'find Port_Binding chassis=fake-chassis-uuid'*) echo 'fake-pb-1'; echo 'fake-pb-2' ;;
    *) exit 0 ;;
esac" "$log"

    PATH="$FAKEBIN:/bin:/usr/bin" "$PRERM" remove
    echo "$log"
}

# --- Part 1: controller is live - existing graceful path, no DB surgery. ---
live_log=$(run_prerm active)
echo "--- live-controller calls ---"
cat "$live_log"
echo "------------------------------"

if ! grep -q '^ovn-ctl --no-monitor stop_controller$' "$live_log"; then
    echo "FAIL: a live controller should still be stopped via ovn-ctl" >&2
    exit 1
fi
if grep -q '^ovn-sbctl' "$live_log"; then
    echo "FAIL: DB-level fallback cleanup ran even though the controller" \
         "was live - it should only run when there's nothing to signal." >&2
    exit 1
fi
echo "PASS: a live controller is stopped via ovn-ctl; no DB fallback runs."

# --- Part 2: controller already stopped - the real bug. ---
stopped_log=$(run_prerm inactive)
echo "--- already-stopped calls ---"
cat "$stopped_log"
echo "-------------------------------"

if grep -q '^ovn-ctl' "$stopped_log"; then
    echo "FAIL: ovn-ctl was invoked even though the controller was already" \
         "stopped - signaling it does nothing, so this accomplishes" \
         "nothing real." >&2
    exit 1
fi
if ! grep -q "destroy Chassis_Private chassis-under-test" "$stopped_log"; then
    echo "FAIL: Chassis_Private was not cleaned up when the controller was" \
         "already stopped - this is exactly the garbage this fix exists" \
         "to prevent." >&2
    exit 1
fi
if ! grep -qE "destroy Chassis( |$)" "$stopped_log"; then
    echo "FAIL: the Chassis row itself was not cleaned up" >&2
    exit 1
fi
for pb in fake-pb-1 fake-pb-2; do
    if ! grep -q "clear Port_Binding $pb chassis" "$stopped_log"; then
        echo "FAIL: Port_Binding $pb's chassis column was not cleared" >&2
        exit 1
    fi
    if ! grep -q "clear Port_Binding $pb encap" "$stopped_log"; then
        echo "FAIL: Port_Binding $pb's encap column was not cleared" >&2
        exit 1
    fi
done
echo "PASS: with the controller already stopped, the DB-level fallback" \
     "released both port bindings and deleted Chassis/Chassis_Private" \
     "directly - no live process needed."
