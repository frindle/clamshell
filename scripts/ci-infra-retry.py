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
  * it was cancelled (and the run is still for the newest commit of its branch, so the
    cancel was not our own concurrency group replacing it).
A job with a failed step is a real failure: tests or the build said so, and a re-run
would only repeat it. Any real failure means no re-run, because `gh run rerun --failed`
would run those jobs again too.
"""
import argparse
import json
import sys

BAD = ("failure", "timed_out", "cancelled", "startup_failure")
GOOD = ("success", "skipped", "neutral")


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
    if any(s.get("conclusion") == "failure" for s in steps):
        return "real", f"{name}: step '{next(s.get('name', '?') for s in steps if s.get('conclusion') == 'failure')}' failed"
    if conclusion == "cancelled":
        return "cancelled", f"{name}: cancelled"
    if conclusion == "timed_out":
        return "real", f"{name}: timed out"
    return "infra", f"{name}: failed with no failed step (runner lost or shut down)"


def decide(jobs_doc, attempt, max_attempts, superseded):
    if attempt >= max_attempts:
        return False, f"attempt {attempt} of {max_attempts} already used"
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
    if superseded and cancelled and not infra:
        return False, "a newer commit replaced this run"
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
