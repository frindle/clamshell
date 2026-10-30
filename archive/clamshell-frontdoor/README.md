# clamshell-frontdoor

A tiny stateless router that sits behind a single "front door" URL and sends
you to whichever interface on the Mac Studio (`TARGET_HOST`) is actually
usable right now, checked fresh on every visit:

1. **Clamshell webclient reachable** &rarr; redirect straight there, no
   intermediate page (the fast path — this is the normal case).
2. **Clamshell down, VNC/Screen Sharing reachable** &rarr; brief status page
   ("Sending to VNC session for login..."), then redirect to VNC.
3. **Neither up, SSH reachable** &rarr; brief status page ("Sending to SSH
   session for FileVault..."), then redirect to the browser-rendered SSH
   terminal (for pre-boot FileVault unlock).
4. **Nothing reachable** &rarr; a real 503 status page, never a dead link.

No persistent state, no background polling — each request just does three
TCP reachability probes and decides. This means the natural flow after
logging in via VNC is: revisit the front-door URL, Clamshell is now up,
step 1 sends you there instead — no extra logic needed for that chain, the
stateless re-check handles it automatically.

Gate this behind the same Cloudflare Access "Penn Only" policy as everything
else in this homelab — it's a routing convenience, not itself an auth
boundary.

## Config (environment variables)

| Var | Default | Meaning |
|---|---|---|
| `TARGET_HOST` | `10.0.15.20` | The Mac's LAN IP |
| `CLAMSHELL_PORT` | `5901` | Clamshell webclient port |
| `VNC_PORT` | `5900` | macOS Screen Sharing/VNC port |
| `SSH_PORT` | `22` | SSH port |
| `CLAMSHELL_URL` | `https://clamshell.penndalton.com` | Redirect target for Clamshell |
| `VNC_URL` | `https://vnc.penndalton.com` | Redirect target for VNC |
| `SSH_URL` | `https://macstudio-ssh.penndalton.com` | Redirect target for the browser SSH terminal — **placeholder, confirm the real hostname once the Cloudflare Access SSH app exists** |
| `TCP_PROBE_TIMEOUT` | `1.5` | Seconds per reachability probe |
| `PORT` | `8080` | Port the Flask app listens on |

## Known limitation

"Clamshell reachable AND a session is logged in" (the spec's step 1) is
approximated here as just "Clamshell's webclient port is reachable" — there
is no separate signal in Clamshell's webclient/API today that distinguishes
"up but nobody's logged in" from "up and logged in." If that distinction
ever matters in practice, it needs a real endpoint on the Clamshell side
first; this service doesn't invent one.

## Local dev

```
pip install -r requirements.txt
python app.py
```

## Deploy

```
docker compose up -d --build
```
