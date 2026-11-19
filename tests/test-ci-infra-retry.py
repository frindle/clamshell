#!/usr/bin/env python3
"""Tests for scripts/ci-infra-retry.py, fed saved (synthetic) job JSON."""
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci-infra-retry.py")
FIX = os.path.join(ROOT, "tests", "ci-retry-fixtures")


def run(fixture, attempt=1, *extra):
    p = subprocess.run(
        [sys.executable, "-I", SCRIPT, "--jobs", os.path.join(FIX, fixture + ".json"),
         "--attempt", str(attempt), *extra],
        capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return p.stdout.strip()


class Decide(unittest.TestCase):
    def test_no_runner_is_rerun(self):
        self.assertTrue(run("infra-no-runner").startswith("rerun:"))

    def test_lost_runner_failed_with_no_failed_step_is_rerun(self):
        self.assertTrue(run("infra-lost-runner").startswith("rerun:"))

    def test_cancelled_by_github_is_rerun(self):
        self.assertTrue(run("infra-cancelled").startswith("rerun:"))

    def test_cancelled_by_newer_push_is_not_rerun(self):
        self.assertTrue(run("infra-cancelled", 1, "--superseded").startswith("no:"))

    def test_superseded_run_cancelled_before_a_step_is_not_rerun(self):
        # A queued run cancelled by a newer push never ran a step; re-running it
        # would cancel the newer run through the shared concurrency group.
        self.assertTrue(run("infra-no-runner", 1, "--superseded").startswith("no:"))
        self.assertTrue(run("infra-lost-runner", 1, "--superseded").startswith("no:"))

    def test_test_failure_is_never_rerun(self):
        out = run("real-test-failure")
        self.assertTrue(out.startswith("no:") and "Unit tests" in out, out)

    def test_real_failure_beside_an_infra_one_is_not_rerun(self):
        self.assertTrue(run("mixed-infra-and-real").startswith("no:"))

    def test_attempt_three_is_not_rerun(self):
        self.assertTrue(run("infra-no-runner", 3).startswith("no:"))
        self.assertTrue(run("infra-lost-runner", 3).startswith("no:"))

    def test_attempt_two_still_reruns(self):
        self.assertTrue(run("infra-no-runner", 2).startswith("rerun:"))

    def test_green_run_is_not_rerun(self):
        self.assertTrue(run("all-green").startswith("no:"))

    def test_bad_file_is_a_usage_error(self):
        p = subprocess.run([sys.executable, "-I", SCRIPT, "--jobs", "/nonexistent.json", "--attempt", "1"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
