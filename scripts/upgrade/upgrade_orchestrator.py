#!/usr/bin/env python3
"""
Phase 2 OVN upgrade orchestrator: rolling pod restart in controlled batches.

Usage:
  python3 upgrade_orchestrator.py \\
    --daemonset ovn-controller \\
    --namespace pf9-infra \\
    --batch-size 25 \\
    --flow-threshold 100 \\
    --validate-wait 30 \\
    [--dry-run]
"""

import argparse
import json
import logging
import subprocess
import sys
import time
from typing import List

log = logging.getLogger("ovn-upgrade")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s"
)


class OrchestratorError(Exception):
    pass


class ValidationError(OrchestratorError):
    pass


def chunk(items: List, size: int) -> List[List]:
    if not items:
        return []
    return [items[i:i + size] for i in range(0, len(items), size)]


def run_kubectl(args: List[str], kubectl: str = "kubectl", timeout: int = 60) -> str:
    cmd = [kubectl] + args
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        raise OrchestratorError(f"kubectl timed out after {timeout}s: {' '.join(cmd)}")
    if result.returncode != 0:
        raise OrchestratorError(
            f"kubectl failed (rc={result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout.strip()


def get_pods_for_daemonset(daemonset: str, namespace: str, kubectl: str) -> List[dict]:
    raw = run_kubectl(
        ["get", "pods", "-n", namespace,
         "-l", f"app={daemonset}",
         "-o", "json"],
        kubectl=kubectl
    )
    data = json.loads(raw)
    return data["items"]


def get_flow_count(pod: str, namespace: str, kubectl: str) -> int:
    try:
        out = run_kubectl(
            ["exec", pod, "-n", namespace, "-c", "ovn-controller",
             "--", "/bin/sh", "-c",
             "ovs-ofctl dump-flows br-int 2>/dev/null | grep -vc '^NXST\\|^OFPST\\|^OFPT' || echo 0"],
            kubectl=kubectl,
            timeout=15
        )
        return int(out.strip())
    except (OrchestratorError, ValueError):
        return 0


def chassis_registered(pod: str, node: str, namespace: str, kubectl: str) -> bool:
    try:
        out = run_kubectl(
            ["exec", pod, "-n", namespace, "-c", "ovn-controller",
             "--", "ovn-sbctl", "show"],
            kubectl=kubectl,
            timeout=15
        )
        return node in out
    except OrchestratorError:
        return False


def validate_node(pod: str, node: str, namespace: str,
                  flow_threshold: int, kubectl: str) -> None:
    count = get_flow_count(pod, namespace, kubectl)
    if count < flow_threshold:
        raise ValidationError(
            f"node {node}: flow count {count} < threshold {flow_threshold}"
        )
    if not chassis_registered(pod, node, namespace, kubectl):
        raise ValidationError(
            f"node {node}: chassis not registered in SB DB"
        )
    log.info("  node %s: flows=%d chassis=OK", node, count)


def wait_for_pods_ready(pods: List[str], namespace: str,
                        kubectl: str, timeout: int = 300) -> None:
    deadline = time.time() + timeout
    pending = set(pods)
    while pending and time.time() < deadline:
        still_pending = set()
        for pod in pending:
            try:
                out = run_kubectl(
                    ["get", "pod", pod, "-n", namespace,
                     "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"],
                    kubectl=kubectl
                )
                if out.strip() != "True":
                    still_pending.add(pod)
            except OrchestratorError:
                still_pending.add(pod)
        pending = still_pending
        if pending:
            time.sleep(5)
    if pending:
        raise OrchestratorError(
            f"Pods not ready after {timeout}s: {', '.join(pending)}"
        )


def delete_pods(pods: List[str], namespace: str, kubectl: str, dry_run: bool) -> None:
    for pod in pods:
        if dry_run:
            log.info("  [dry-run] delete pod %s", pod)
        else:
            run_kubectl(["delete", "pod", pod, "-n", namespace], kubectl=kubectl)
            log.info("  deleted pod %s", pod)


def run(daemonset: str, namespace: str, batch_size: int,
        flow_threshold: int, validate_wait: int,
        kubectl: str, dry_run: bool) -> None:

    log.info("Fetching pods for DaemonSet %s in namespace %s", daemonset, namespace)
    pods = get_pods_for_daemonset(daemonset, namespace, kubectl)

    nodes = [
        (p["metadata"]["name"], p["spec"]["nodeName"])
        for p in pods
    ]
    log.info("Found %d nodes", len(nodes))

    batches = chunk(nodes, batch_size)
    log.info("Splitting into %d batches of %d", len(batches), batch_size)

    for batch_num, batch in enumerate(batches, 1):
        pod_names = [n[0] for n in batch]
        node_names = [n[1] for n in batch]
        log.info("--- Batch %d/%d: %s", batch_num, len(batches), ", ".join(node_names))

        log.info("  Pre-check...")
        for pod, node in batch:
            validate_node(pod, node, namespace, flow_threshold, kubectl)

        log.info("  Deleting pods...")
        delete_pods(pod_names, namespace, kubectl, dry_run)

        if dry_run:
            log.info("  [dry-run] skipping wait and validation")
            continue

        log.info("  Waiting for pods to reach Ready...")
        time.sleep(5)
        new_pods = get_pods_for_daemonset(daemonset, namespace, kubectl)
        new_batch_pods = [
            p["metadata"]["name"] for p in new_pods
            if p["spec"]["nodeName"] in node_names
        ]
        wait_for_pods_ready(new_batch_pods, namespace, kubectl, timeout=300)

        log.info("  Waiting %ds for reconciliation...", validate_wait)
        time.sleep(validate_wait)

        log.info("  Validating batch...")
        current_pods = get_pods_for_daemonset(daemonset, namespace, kubectl)
        for pod_info in current_pods:
            node = pod_info["spec"]["nodeName"]
            if node in node_names:
                pod = pod_info["metadata"]["name"]
                validate_node(pod, node, namespace, flow_threshold, kubectl)

        log.info("  Batch %d/%d complete.", batch_num, len(batches))

    log.info("=== All %d batches complete. Upgrade successful. ===", len(batches))


def main():
    parser = argparse.ArgumentParser(description="OVN rolling controller upgrade orchestrator")
    parser.add_argument("--daemonset",      required=True, help="DaemonSet name")
    parser.add_argument("--namespace",      required=True, help="Kubernetes namespace")
    parser.add_argument("--batch-size",     type=int, default=25)
    parser.add_argument("--flow-threshold", type=int, default=100,
                        help="Minimum flow count for a healthy node")
    parser.add_argument("--validate-wait",  type=int, default=30,
                        help="Seconds to wait after pods are Ready before validating")
    parser.add_argument("--kubectl",        default="kubectl")
    parser.add_argument("--dry-run",        action="store_true")
    args = parser.parse_args()

    try:
        run(
            daemonset=args.daemonset,
            namespace=args.namespace,
            batch_size=args.batch_size,
            flow_threshold=args.flow_threshold,
            validate_wait=args.validate_wait,
            kubectl=args.kubectl,
            dry_run=args.dry_run,
        )
    except OrchestratorError as e:
        log.error("HALT: %s", e)
        log.error("Check affected nodes. Rollback: delete pods on affected nodes")
        log.error("to trigger a fresh restart (wait_before_clear protects flows).")
        sys.exit(1)


if __name__ == "__main__":
    main()
