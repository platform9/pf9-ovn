# OVN Zero-Downtime Upgrade Runbook

Reference: `docs/superpowers/specs/2026-04-22-ovn-zero-downtime-upgrade-design.md`

## Prerequisites

- `kubectl` configured for the target cluster
- `DAEMONSET`, `NAMESPACE`, and `OVN_IMAGE` exported:
  ```bash
  export DAEMONSET=ovn-controller
  export NAMESPACE=pf9-infra
  export OVN_IMAGE=<registry>/<repo>:<new-tag>
  ```

---

## Phase 0: Prepare (no downtime)

### 0a. Apply DaemonSet patches

Switches to OnDelete strategy, adds preStop hook, HostPath volumes, init container, and flow-watchdog sidecar.

```bash
# Dry-run first
pf9-ovn/scripts/upgrade/apply_daemonset_patches.sh \
  --daemonset "$DAEMONSET" \
  --namespace "$NAMESPACE" \
  --image     "$OVN_IMAGE" \
  --dry-run

# Apply
pf9-ovn/scripts/upgrade/apply_daemonset_patches.sh \
  --daemonset "$DAEMONSET" \
  --namespace "$NAMESPACE" \
  --image     "$OVN_IMAGE"
```

Verify: `kubectl get ds "$DAEMONSET" -n "$NAMESPACE" -o jsonpath='{.spec.updateStrategy.type}'`
Expected: `OnDelete`

### 0b. Register new image (pods NOT replaced yet)

```bash
kubectl set image daemonset/"$DAEMONSET" \
  ovn-controller="$OVN_IMAGE" \
  -n "$NAMESPACE"
```

Verify: `kubectl get ds "$DAEMONSET" -n "$NAMESPACE"` — DESIRED and READY counts unchanged.

### 0c. Set wait_before_clear to 30 minutes on all nodes

Required before DB migration. Protects existing flows for up to 30 minutes of DB downtime.

```bash
# Dry-run first
pf9-ovn/scripts/upgrade/set_wait_before_clear.sh \
  --daemonset "$DAEMONSET" \
  --namespace "$NAMESPACE" \
  --value 1800000 \
  --dry-run

# Apply
pf9-ovn/scripts/upgrade/set_wait_before_clear.sh \
  --daemonset "$DAEMONSET" \
  --namespace "$NAMESPACE" \
  --value 1800000
```

Verify on a sample node:
```bash
kubectl exec <any-pod> -n "$NAMESPACE" -c ovn-controller -- \
  ovs-vsctl get open . external_ids:ovn-ofctrl-wait-before-clear
```
Expected: `"1800000"`

---

## Phase 1: DB PVC Migration (controllers stay running — no downtime)

Follow the existing PVC migration runbook:
https://platform9.atlassian.net/wiki/spaces/SUP/pages/5911707649/

Scale down order: neutron → relay → northd
Migrate PVCs (gp2 → gp3)
Scale up order: northd → relay → neutron

Existing VM flows are preserved throughout by `wait_before_clear=30min`.

Verify after Phase 1:
```bash
kubectl get po -n "$NAMESPACE" | grep -E "ovn|neutron"
kubectl exec <ovn-ovsdb-nb-pod> -n "$NAMESPACE" -- ovn-nbctl show | head -5
kubectl exec <ovn-ovsdb-sb-pod> -n "$NAMESPACE" -- ovn-sbctl show | head -5
```

---

## Phase 2: Rolling controller restart (DB hot — <30ms downtime per node)

### 2a. Lower wait_before_clear to 30 seconds

```bash
pf9-ovn/scripts/upgrade/set_wait_before_clear.sh \
  --daemonset "$DAEMONSET" \
  --namespace "$NAMESPACE" \
  --value 30000
```

### 2b. Run the upgrade orchestrator

```bash
# Dry-run to verify batch structure
python3 pf9-ovn/scripts/upgrade/upgrade_orchestrator.py \
  --daemonset     "$DAEMONSET" \
  --namespace     "$NAMESPACE" \
  --batch-size    25 \
  --flow-threshold 100 \
  --validate-wait 30 \
  --dry-run

# Execute (logs each batch with pre/post validation)
python3 pf9-ovn/scripts/upgrade/upgrade_orchestrator.py \
  --daemonset     "$DAEMONSET" \
  --namespace     "$NAMESPACE" \
  --batch-size    25 \
  --flow-threshold 100 \
  --validate-wait 30
```

The orchestrator halts with exit code 1 if any node fails validation. See Rollback below.

### 2c. Verify all nodes on new image

```bash
kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' \
  | grep ovn-controller
```

Expected: all pods show `$OVN_IMAGE`.

---

## Expected Downtime Summary

| Phase | Impact |
|-------|--------|
| Phase 0 | 0 ms |
| Phase 1 (DB migration) | 0 ms for existing VMs; new VM provisioning fails during DB offline (~10–30 min) |
| Phase 2 per node (primary path) | 1–30 ms (atomic bundle commit, wait_before_clear pre-computes flows) |
| Phase 2 per node (watchdog fallback) | 50–550 ms (flow snapshot restore) |
| Total window (600 hosts, batch=25) | ~30–60 minutes end-to-end |

---

## Rollback

### Phase 1 rollback

Follow the existing runbook rollback. All controller pods are on the old image (OnDelete — no pods replaced yet). No networking changes on compute hosts.

### Phase 2 rollback — orchestrator halted

1. Identify affected nodes from the orchestrator log output.
2. Force a fresh pod start for each unhealthy node:
   ```bash
   kubectl delete pod <pod-name> -n "$NAMESPACE"
   ```
   With `wait_before_clear=30s` and hot DB, each node recovers in ~45 seconds.
3. To abandon Phase 2 and stay on the old image entirely:
   ```bash
   kubectl set image daemonset/"$DAEMONSET" ovn-controller=<OLD_IMAGE> -n "$NAMESPACE"
   ```
   Pods not yet replaced (OnDelete) keep running the old image.

### Emergency: clear stale flows immediately

If stale flows are causing traffic issues after a failed upgrade:
```bash
kubectl exec <pod> -n "$NAMESPACE" -c ovn-controller -- \
  ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=0
```
Takes effect on the next controller reconnection event.
