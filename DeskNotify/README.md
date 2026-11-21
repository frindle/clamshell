# DeskNotify

Notification and Dock badge bridge (plan section 3.3).

Host side: `SQLiteNotificationStore` + `NotificationStoreReader` find new rows in the
notification store; `HostNotifyBridge` and `BadgeWatcher` turn them into v3 NOTIFY and BADGE
messages for the apps on the allowlist. `DockAccessibilitySource` reads badges (macOS only).

Operator side: `NotificationGate` decides (dedupe, rate limit, focus, Do Not Disturb) and maps
the hosted bundle id to the stub bundle id. `OperatorBridge` hands the result to a
`NotificationPoster` and `BadgeSetter`. The real poster runs inside the stub process, so the
banner carries the stub's icon.

Needs Full Disk Access (store) and Accessibility (Dock) on the host. Logs hold metadata only.
