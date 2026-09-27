# HANDOFF — window-handoff-v2 branch (delete in final commit)

Resume checklist: `git -C <worktree> branch --show-current` must print
`window-handoff-v2` and the path must be the agent worktree under
`.claude/worktrees/`, never the primary checkout.

## Done
- Review fixes (4 commits): WebServer negative Content-Length trap,
  selectWindowStream stop/start port race, InputInjector flag mask,
  StreamServer window source `onScreenWindowsOnly: false` + AX note.

## In progress
- Peer link protocol (0x40+) — Swift + C# builders/parsers + selftests.

## Next
- Mac PeerLink (Bonjour + WS on 5910 + PIN/ECDSA pairing) + selftest
- Mac EdgeController (CGEventTap KVM) / RemoteInputSink
- Mac clipboard peer mode, file transfer, drag-drop trigger
- Mac window handoff source (hide via AX) + ReceiverWindow
- Windows: PeerLink (HttpListener WS + Makaretu mDNS), EdgeController hooks,
  WindowSource (WGC), ReceiverForm, FileTransfer, clipboard
- windows-ci.yml selftest steps; PROTOCOL.md; README Unreleased; test plan
