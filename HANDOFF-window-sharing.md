# HANDOFF — window-handoff-v2 branch (delete in final commit)

Resume checklist: `git -C <worktree> branch --show-current` must print
`window-handoff-v2` and the path must be the agent worktree under
`.claude/worktrees/`, never the primary checkout.

## Done
- Review fixes (4 commits): WebServer negative Content-Length trap,
  selectWindowStream stop/start port race, InputInjector flag mask,
  StreamServer window source `onScreenWindowsOnly: false` + AX note.

- Peer link protocol (0x40+): Sources/Clamshell/Peer/PeerProtocol.swift,
  PeerIdentity.swift (P-256 id file, PIN HMAC, trust store), PeerLink.swift
  (Bonjour advertise/browse, WS 5910, mutual ECDSA auth). Selftests:
  `peer-protocol-selftest`, `peer-link-selftest` (loopback 5998/5999) PASS.
  Gotchas: WS NWConnection client must dial a `.url` endpoint; receive only
  after `.ready`; refusal ACK sent before close.

## In progress
- Mac PeerManager wiring (EdgeController / RemoteInputSink / clipboard /
  file transfer / handoff) — nothing written yet.

## Next
- Mac EdgeController (CGEventTap KVM) / RemoteInputSink
- Mac clipboard peer mode, file transfer, drag-drop trigger
- Mac window handoff source (hide via AX) + ReceiverWindow
- Windows: PeerLink (HttpListener WS + Makaretu mDNS), EdgeController hooks,
  WindowSource (WGC), ReceiverForm, FileTransfer, clipboard
- windows-ci.yml selftest steps; PROTOCOL.md; README Unreleased; test plan
