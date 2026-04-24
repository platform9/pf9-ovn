#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 --daemonset <name> --namespace <ns> --value <ms> [--dry-run]"
    echo ""
    echo "  --value    Value in ms. Use 1800000 before DB migration, 30000 after."
    exit 1
}

DAEMONSET="" NAMESPACE="" VALUE="" DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --daemonset) DAEMONSET="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --value)     VALUE="$2";     shift 2 ;;
        --dry-run)   DRY_RUN=true;   shift ;;
        *) usage ;;
    esac
done

[ -z "$DAEMONSET" ] || [ -z "$NAMESPACE" ] || [ -z "$VALUE" ] && usage

echo "Setting ovn-ofctrl-wait-before-clear=$VALUE on all ovn-controller pods..."

PODS=$(kubectl get pods -n "$NAMESPACE" \
    -l "$(kubectl get daemonset "$DAEMONSET" -n "$NAMESPACE" \
          -o jsonpath='{.spec.selector.matchLabels}' \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(f'{k}={v}' for k,v in d.items()))")" \
    -o jsonpath='{.items[*].metadata.name}')

COUNT=0
for POD in $PODS; do
    NODE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
    if $DRY_RUN; then
        echo "  [dry-run] $POD ($NODE): ovs-vsctl set open . external_ids:ovn-ofctrl-wait-before-clear=$VALUE"
    else
        kubectl exec "$POD" -n "$NAMESPACE" -c ovn-controller -- \
            ovs-vsctl set open . "external_ids:ovn-ofctrl-wait-before-clear=$VALUE"
        echo "  OK: $POD ($NODE)"
    fi
    COUNT=$((COUNT+1))
done

echo ""
echo "Done. Updated $COUNT pods. Value: ${VALUE}ms"
if $DRY_RUN; then echo "(dry-run — no changes made)"; fi
