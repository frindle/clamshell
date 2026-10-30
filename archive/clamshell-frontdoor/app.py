"""Homelab front-door router service.

A tiny stateless Flask app that, on every GET / request, performs live TCP
reachability probes against a target Mac (Clamshell, VNC, SSH) and redirects
the browser to whichever interface is currently up.  There is NO persistent
state, NO background polling, and NO caching -- a fresh check on every visit
is intentional, not a missing feature.  This keeps the service trivially
simple and always reflects the Mac's real-time availability.
"""

import logging
import os
import socket

from flask import Flask, redirect, Response

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------
TARGET_HOST = os.environ.get("TARGET_HOST", "10.0.15.20")
CLAMSHELL_PORT = int(os.environ.get("CLAMSHELL_PORT", "5901"))
VNC_PORT = int(os.environ.get("VNC_PORT", "5900"))
SSH_PORT = int(os.environ.get("SSH_PORT", "22"))
CLAMSHELL_URL = os.environ.get("CLAMSHELL_URL", "https://clamshell.penndalton.com")
VNC_URL = os.environ.get("VNC_URL", "https://vnc.penndalton.com")
SSH_URL = os.environ.get("SSH_URL", "https://macstudio-ssh.penndalton.com")
TCP_PROBE_TIMEOUT = float(os.environ.get("TCP_PROBE_TIMEOUT", "1.5"))
PORT = int(os.environ.get("PORT", "8080"))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    format="%(asctime)s %(levelname)s %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("frontdoor")

# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------
app = Flask(__name__)


def _tcp_reachable(host: str, port: int, timeout: float) -> bool:
    """Return True if a TCP connection to host:port succeeds within timeout.

    Any exception (DNS failure, OSError, etc.) is treated as unreachable.
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        result = s.connect_ex((host, port))
        s.close()
        return result == 0
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Inline HTML templates (dark-theme, centered, no external assets)
# ---------------------------------------------------------------------------

_REDIRECT_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="1;url={url}">
<title>Redirecting</title>
<style>
  body {{
    background: #111827;
    color: #d1d5db;
    font-family: ui-monospace, 'SF Mono', Menlo, monospace;
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
    margin: 0;
  }}
  p {{
    font-size: 1.1rem;
    letter-spacing: 0.02em;
  }}
</style>
</head>
<body>
<p>{message}</p>
</body>
</html>"""

_UNAVAILABLE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Service Unavailable</title>
<style>
  body {{
    background: #111827;
    color: #d1d5db;
    font-family: ui-monospace, 'SF Mono', Menlo, monospace;
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
    margin: 0;
  }}
  div {{
    text-align: center;
  }}
  h1 {{
    font-size: 1.3rem;
    color: #f87171;
    margin-bottom: 0.5rem;
  }}
  p {{
    font-size: 1rem;
    color: #9ca3af;
  }}
</style>
</head>
<body>
<div>
  <h1>503 &mdash; No Interface Reachable</h1>
  <p>None of the target interfaces (Clamshell, VNC, SSH) are currently
  responding. The Mac may be asleep, powered off, or the network path is
  down. Please try again in a moment.</p>
</div>
</body>
</html>"""


# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    # 1. Clamshell (fast path)
    if _tcp_reachable(TARGET_HOST, CLAMSHELL_PORT, TCP_PROBE_TIMEOUT):
        log.info(
            "Clamshell reachable (%s:%d) -> redirecting to %s",
            TARGET_HOST, CLAMSHELL_PORT, CLAMSHELL_URL,
        )
        return redirect(CLAMSHELL_URL, code=302)

    # 2. VNC
    if _tcp_reachable(TARGET_HOST, VNC_PORT, TCP_PROBE_TIMEOUT):
        log.info(
            "Clamshell down, VNC reachable (%s:%d) -> redirecting to %s",
            TARGET_HOST, VNC_PORT, VNC_URL,
        )
        html = _REDIRECT_TEMPLATE.format(
            url=VNC_URL,
            message="Sending to VNC session for login...",
        )
        return Response(html, status=200, mimetype="text/html")

    # 3. SSH
    if _tcp_reachable(TARGET_HOST, SSH_PORT, TCP_PROBE_TIMEOUT):
        log.info(
            "Clamshell & VNC down, SSH reachable (%s:%d) -> redirecting to %s",
            TARGET_HOST, SSH_PORT, SSH_URL,
        )
        html = _REDIRECT_TEMPLATE.format(
            url=SSH_URL,
            message="Sending to SSH session for FileVault...",
        )
        return Response(html, status=200, mimetype="text/html")

    # 4. Nothing reachable
    log.info(
        "No interface reachable on %s (checked ports %d, %d, %d) -> 503",
        TARGET_HOST, CLAMSHELL_PORT, VNC_PORT, SSH_PORT,
    )
    return Response(_UNAVAILABLE_TEMPLATE, status=503, mimetype="text/html")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
