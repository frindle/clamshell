# E7 probe: notifications and Dock badges

Answers plan test E7: can a host agent read new notifications (app, title, body) within 2 seconds,
and read Dock badges, on macOS 27?

- Read-only. Logs metadata only; full text only for test notifications titled "E7 probe ...".
- Needs Full Disk Access (notification store) and Accessibility (Dock badges). Both are retried
  while it runs, so no relaunch is needed after toggling them.
- Built and signed ad hoc in CI (`.github/workflows/desk-probes.yml`); download the artifact.

Run: `open -g NotifProbe.app --args 900` and read `~/Library/Logs/NotifProbe/probe.log`.
Send a test: `osascript -e 'display notification "hello" with title "E7 probe 1"'`.
