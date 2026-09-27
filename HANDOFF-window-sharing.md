# HANDOFF — window-handoff-v2 branch (delete in final commit)

Resume checklist: `git -C <worktree> branch --show-current` must print
`window-handoff-v2` and the path must be the agent worktree under
`.claude/worktrees/`, never the primary checkout. Never write to the real
~/Library/Application Support/Clamshell when smoke-testing: run
`CLAMSHELL_PEER_DIR=<scratch> .build/debug/Clamshell peer --no-advertise --port 5996`.

## Done
- Review fixes (4 commits), peer link protocol (0x40+), PeerIdentity,
  PeerLink (Bonjour, WS 5910, mutual ECDSA). Selftests
  `peer-protocol-selftest`, `peer-link-selftest` PASS.
- InputInjector: CLAM-tagged private event source (`isInjected`), peer
  modifier state stamped on mouse events, `releaseAll()`, double-click
  clickState, off-screen window target → `postToPid` with window number.
- Mac KVM slice: Peer/EdgeGeometry.swift (pure edge/virtual-cursor/key
  rules), CarryDetector (drag pasteboard + moved-window detection),
  EdgeController (session CGEventTap, CursorOps seam), RemoteInputSink
  (carry mode), PeerManager (routing, auto-reconnect: smaller id dials),
  PeerMenu ("Shared Desk" submenu in StatusBarApp), `clamshell peer` CLI,
  `clamshell edge-selftest` PASS (43 checks). PeerLink.remoteHost added.
  `PeerFeatures.install(on:)` / `menuItems(for:)` in PeerCommand.swift is the
  hook where clipboard/files/handoff modules get attached.

- Mac clipboard + files slice: PeerClipboard (text via CLIPBOARD, PNG via
  CLIPBOARD_DATA kind 1, PNG+TIFF on paste, no echo), FileTransfer (auto-
  accept to ~/Downloads via hidden .part, sha256 verify, folders → ditto zip,
  8 chunks in flight, 4 incoming max), PeerFeatures.swift wires routes and
  the drag triggers (onCarryDropped / onPeerLeftCarrying → files.send),
  "Send Files to …" menu item, `peer --send path`. `peer-files-selftest` PASS.

- Mac window handoff slice: WindowHider (AX window found by pid + frame
  match, parked in the display's bottom-right corner, restored to the
  pre-drag origin), StreamServer(allowedRemoteHost:, windowScale:),
  ReceiverWindow (borderless, AVSampleBufferDisplayLayer, title strip with
  "Send back", follows the cursor while the carrying drag is held),
  HandoffManager (ports 5921-5940, 15 s accept timeout, 1 s closed-window
  watcher, reset on unlink), wired in PeerFeatures (window crossing → begin,
  receiver crossing → HANDOFF_RETURN, "Bring Back Handed-off Windows").
  `handoff-selftest` PASS incl. park/restore — the Aug AX fault no longer
  reproduces (the earlier miss was an unsettled window frame).

## Design decisions (keep consistent on Windows)
- Controller keeps a virtual cursor in the peer's units (screen size from
  HELLO), sends EDGE_ENTER(edge of peer screen, x, y, carry) then v1
  INPUT_MOUSE_MOVE normalized; leaving through the entry edge sends
  EDGE_LEAVE. Delta scale = clamp(peerW/localW, 0.5, 3).
- Crossing with the left button down only when carrying (files / moved
  window / our ReceiverWindow); otherwise blocked at the edge.
- EDGE_ENTER leftButtonDown=1 = carry: receiver injects no press and
  swallows the next left release (ends carry).
- EDGE_LEAVE on the controlled side with its injected left button down →
  evaluate carry there (files → send to peer, window → handoff to peer,
  receiver window → HANDOFF_RETURN).
- Panic key Ctrl+Opt+Cmd+L (Windows: Ctrl+Alt+Win+L? pick Ctrl+Alt+Shift+L).
- Controlled side maps to its primary display only (documented gap).

## Next
- Windows: PeerProtocol/Identity/Link (TcpListener + manual WS upgrade, no
  URL ACL; mDNS), EdgeController hooks, WindowSource (WGC), ReceiverForm,
  FileTransfer, clipboard. Golden byte vectors shared with Swift selftest.
- windows-ci.yml selftest steps; PROTOCOL.md; README Unreleased; test plan
