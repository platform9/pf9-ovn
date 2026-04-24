#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 --daemonset <name> --namespace <ns> --image <image> [--dry-run]"
    echo ""
    echo "  --daemonset   DaemonSet name for ovn-controller"
    echo "  --namespace   Kubernetes namespace"
    echo "  --image       Full image reference for sidecar/init containers"
    echo "  --dry-run     Validate patches without applying"
    exit 1
}

DAEMONSET=""
NAMESPACE=""
IMAGE=""
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --daemonset)  DAEMONSET="$2";  shift 2 ;;
        --namespace)  NAMESPACE="$2";  shift 2 ;;
        --image)      IMAGE="$2";      shift 2 ;;
        --dry-run)    DRY_RUN="--dry-run=server"; shift ;;
        *) usage ;;
    esac
done

[ -z "$DAEMONSET" ] || [ -z "$NAMESPACE" ] || [ -z "$IMAGE" ] && usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"

apply_patch() {
    local patch_file="$1"
    local description="$2"
    echo "Applying: $description"
    local patched
    patched=$(sed "s|REPLACE_WITH_OVN_IMAGE|$IMAGE|g" "$patch_file")
    echo "$patched" | kubectl patch daemonset "$DAEMONSET" \
        -n "$NAMESPACE" \
        --type=json \
        --patch="$patched" \
        $DRY_RUN
    echo "  OK"
}

echo "=== OVN DaemonSet patches ==="
echo "    DaemonSet : $DAEMONSET"
echo "    Namespace : $NAMESPACE"
echo "    Image     : $IMAGE"
echo "    Mode      : ${DRY_RUN:-apply}"
echo ""

apply_patch "$PATCH_DIR/01-on-delete-strategy.json"     "01 - OnDelete update strategy"
apply_patch "$PATCH_DIR/02-prestop-volumes.json"        "02 - preStop hook + HostPath volumes"
apply_patch "$PATCH_DIR/03-init-wait-before-clear.json" "03 - init container (wait_before_clear=30s)"
apply_patch "$PATCH_DIR/04-watchdog-sidecar.json"       "04 - flow-watchdog sidecar"

echo ""
echo "All patches applied successfully."
if [ -n "$DRY_RUN" ]; then
    echo "(dry-run mode — no changes were made)"
fi
