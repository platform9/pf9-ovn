import sys
import os
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import upgrade_orchestrator as orch


class TestChunk(unittest.TestCase):
    def test_even_split(self):
        nodes = [f"node{i}" for i in range(10)]
        batches = orch.chunk(nodes, 3)
        self.assertEqual(len(batches), 4)
        self.assertEqual(batches[0], ["node0", "node1", "node2"])
        self.assertEqual(batches[-1], ["node9"])

    def test_empty(self):
        self.assertEqual(orch.chunk([], 5), [])

    def test_batch_larger_than_list(self):
        batches = orch.chunk(["node0", "node1"], 10)
        self.assertEqual(len(batches), 1)
        self.assertEqual(batches[0], ["node0", "node1"])


class TestRunKubectl(unittest.TestCase):
    def test_returns_stdout(self):
        result = orch.run_kubectl(["-c", "echo hello"], kubectl="/bin/sh")
        self.assertIn("hello", result)

    def test_raises_on_nonzero(self):
        with self.assertRaises(orch.OrchestratorError):
            orch.run_kubectl(["-c", "exit 1"], kubectl="/bin/sh")


class TestValidateNode(unittest.TestCase):
    def test_healthy_passes(self):
        with patch("upgrade_orchestrator.get_flow_count", return_value=1500), \
             patch("upgrade_orchestrator.chassis_registered", return_value=True):
            orch.validate_node("pod0", "node0", "pf9-infra", 10, "kubectl")

    def test_low_flow_raises(self):
        with patch("upgrade_orchestrator.get_flow_count", return_value=5), \
             patch("upgrade_orchestrator.chassis_registered", return_value=True):
            with self.assertRaises(orch.ValidationError):
                orch.validate_node("pod0", "node0", "pf9-infra", 10, "kubectl")

    def test_chassis_not_registered_raises(self):
        with patch("upgrade_orchestrator.get_flow_count", return_value=1500), \
             patch("upgrade_orchestrator.chassis_registered", return_value=False):
            with self.assertRaises(orch.ValidationError):
                orch.validate_node("pod0", "node0", "pf9-infra", 10, "kubectl")


class TestGetFlowCount(unittest.TestCase):
    def test_returns_count(self):
        with patch("upgrade_orchestrator.run_kubectl", return_value="1500"):
            count = orch.get_flow_count("pod0", "pf9-infra", "kubectl")
            self.assertEqual(count, 1500)

    def test_returns_zero_on_error(self):
        with patch("upgrade_orchestrator.run_kubectl", side_effect=orch.OrchestratorError("fail")):
            count = orch.get_flow_count("pod0", "pf9-infra", "kubectl")
            self.assertEqual(count, 0)


class TestChassisRegistered(unittest.TestCase):
    def test_found(self):
        with patch("upgrade_orchestrator.run_kubectl", return_value="chassis=node0\nchassis=node1"):
            self.assertTrue(orch.chassis_registered("pod0", "node0", "pf9-infra", "kubectl"))

    def test_not_found(self):
        with patch("upgrade_orchestrator.run_kubectl", return_value=""):
            self.assertFalse(orch.chassis_registered("pod0", "node0", "pf9-infra", "kubectl"))

    def test_error_returns_false(self):
        with patch("upgrade_orchestrator.run_kubectl", side_effect=orch.OrchestratorError("fail")):
            self.assertFalse(orch.chassis_registered("pod0", "node0", "pf9-infra", "kubectl"))


if __name__ == "__main__":
    unittest.main()
