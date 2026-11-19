#!/usr/bin/env python3
"""Decide whether a failed CI run failed for infrastructure reasons and should be re-run.

Used by .github/workflows/ci-auto-retry.yml. Reads the run's jobs as returned by
`GET /repos/{repo}/actions/runs/{id}/attempts/{n}/jobs` (a JSON object with a "jobs" list)
and prints one line: "rerun: <why>" or "no: <why>". Exit status is 0 either way; only a
bad invocation is non-zero. Pure: no network, no clock.

A job counts as an infrastructure failure when it did not fail on its own account:
  * it never ran a step (no runner was found, the runner was lost before the first step,
    or GitHub failed the job before it started);
  * it ended "failure" but none of its steps failed (the runner was lost or shut down
    while a step was running);
  * it was cancelled;
  * its only failed steps are setup steps (runner setup, checkout, toolchain or package
    installs; see SETUP_STEPS): a download that timed out, not our code.
A run for a commit its branch has moved past is never re-run, whatever the cause: the
newer commit has its own run, and a re-run would join the same concurrency group and
cancel that newer run (which would then be re-run in turn).
A job with a failed step is a real failure: tests or the build said so, and a re-run
would only repeat it. Any real failure means no re-run, because `gh run rerun --failed`
would run those jobs again too.
"""
import argparse
import json
import sys

BAD = ("failure", "timed_out", "cancelled", "startup_failure")
GOOD = ("success", "skipped", "neutral")
# Step names (prefixes) that only fetch or set up tools. When one of these is the only
# failed step, the job failed on a download or the runner, not on our code. Matches the
# names GitHub gives these steps and the install steps in ci.yml and windows-ci.yml.
SETUP_STEPS = ("Set up job", "Run actions/checkout", "Run actions/setup-", "Install ")


def is_setup_step(step):
    return (step.get("name") or "").startswith(SETUP_STEPS)


def classify(job):
    """Returns ("ok" | "infra" | "cancelled" | "real", reason)."""
    name = job.get("name", "?")
    conclusion = job.get("conclusion")
    if conclusion in GOOD:
        return "ok", ""
    steps = job.get("steps") or []
    if conclusion == "startup_failure":
        return "infra", f"{name}: startup failure"
    if conclusion not in BAD:
        # still running, queued, or null: nothing to decide on
        return "ok", ""
    if not steps or all(s.get("status") == "queued" for s in steps):
        return "infra", f"{name}: no step ever ran (no runner, or it was lost before starting)"
    failed = [s for s in steps if s.get("conclusion") == "failure"]
    if failed and all(is_setup_step(s) for s in failed):
        return "infra", f"{name}: setup step '{failed[0].get('name', '?')}' failed (download or runner)"
    if failed:
        real = next((s for s in failed if not is_setup_step(s)), failed[0])
        return "real", f"{name}: step '{real.get('name', '?')}' failed"
    if conclusion == "cancelled":
        return "cancelled", f"{name}: cancelled"
    if conclusion == "timed_out":
        return "real", f"{name}: timed out"
    return "infra", f"{name}: failed with no failed step (runner lost or shut down)"


def decide(jobs_doc, attempt, max_attempts, superseded):
    if attempt >= max_attempts:
        return False, f"attempt {attempt} of {max_attempts} already used"
    if superseded:
        return False, "a newer commit replaced this run"
    jobs = jobs_doc.get("jobs") or []
    if not jobs:
        return False, "no jobs in the run"
    infra, cancelled, real = [], [], []
    for job in jobs:
        kind, why = classify(job)
        if kind == "infra":
            infra.append(why)
        elif kind == "cancelled":
            cancelled.append(why)
        elif kind == "real":
            real.append(why)
    if real:
        return False, "real failure: " + "; ".join(real)
    if not infra and not cancelled:
        return False, "no failed job found"
    return True, "; ".join(infra + cancelled)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", required=True, help="JSON file with the run's jobs")
    ap.add_argument("--attempt", type=int, required=True, help="run_attempt of the failed run")
    ap.add_argument("--max-attempts", type=int, default=3)
    ap.add_argument("--superseded", action="store_true",
                    help="the branch has a newer commit than the run's")
    args = ap.parse_args(argv)
    try:
        with open(args.jobs) as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        print(f"bad jobs file: {e}", file=sys.stderr)
        return 2
    go, why = decide(doc, args.attempt, args.max_attempts, args.superseded)
    print(("rerun: " if go else "no: ") + why)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
