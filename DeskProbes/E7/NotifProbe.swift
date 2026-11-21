// E7 probe: can a host agent read new notifications and Dock badges on this Mac?
//
// Read-only. It never posts, clears or changes a notification, and never touches the Dock.
// Privacy: the log holds metadata only (app id, field lengths, latency). The full title and body
// are logged only for notifications whose title starts with "E7 probe", the ones the test sends.
//
// Needs Full Disk Access (notification store) and Accessibility (Dock badges). Both are retried
// while it runs, so toggling them in System Settings takes effect without a relaunch.
//
// Usage:  open -g NotifProbe.app --args 900      (seconds to run; default 900)
// Log:    ~/Library/Logs/NotifProbe/probe.log
import AppKit
import ApplicationServices
import Foundation
import SQLite3

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let logDir = home.appendingPathComponent("Library/Logs/NotifProbe")
try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
let logURL = logDir.appendingPathComponent("probe.log")
if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
let logHandle = try! FileHandle(forWritingTo: logURL)
logHandle.seekToEndOfFile()
let stamp = ISO8601DateFormatter()
stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func say(_ s: String) { logHandle.write(Data("\(stamp.string(from: Date())) \(s)\n".utf8)) }

let numericArgs = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let duration = numericArgs.first ?? 900
let marker = "E7 probe"

// MARK: notification store

let dbPath = home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
var db: OpaquePointer?
var lastRec: Int64 = -1
var recordCols: Set<String> = []
var seen = 0

func rows(_ sql: String, _ binds: [Int64] = [], _ each: (OpaquePointer) -> Void) -> Bool {
  var st: OpaquePointer?
  guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { return false }
  defer { sqlite3_finalize(s) }
  for (i, b) in binds.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), b) }
  while true {
    let rc = sqlite3_step(s)
    if rc == SQLITE_ROW { each(s) } else { return rc == SQLITE_DONE }
  }
}
func text(_ s: OpaquePointer, _ i: Int32) -> String {
  guard let c = sqlite3_column_text(s, i) else { return "" }
  return String(cString: c)
}

func openStore() -> Bool {
  if db != nil { return true }
  var h: OpaquePointer?
  let rc = sqlite3_open_v2(dbPath, &h, SQLITE_OPEN_READONLY, nil)
  guard rc == SQLITE_OK, let handle = h else { sqlite3_close(h); return false }
  // Opening can succeed without access; the first read is the real test.
  db = handle
  var tables: [String] = []
  guard rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", [], { tables.append(text($0, 0)) }) else {
    sqlite3_close(handle); db = nil; return false
  }
  say("store: open (Full Disk Access works). tables=\(tables.joined(separator: ","))")
  _ = rows("PRAGMA table_info(record)") { recordCols.insert(text($0, 1)) }
  say("store: record columns=\(recordCols.sorted().joined(separator: ","))")
  var count: Int64 = 0
  _ = rows("SELECT count(*), coalesce(max(rec_id), 0) FROM record") { count = sqlite3_column_int64($0, 0); lastRec = sqlite3_column_int64($0, 1) }
  say("store: \(count) rows; watching for rec_id > \(lastRec)")
  return true
}

func appID(_ id: Int64) -> String {
  var name = "app#\(id)"
  _ = rows("SELECT identifier FROM app WHERE app_id = ?", [id]) { name = text($0, 0) }
  return name
}

func pollStore() {
  guard openStore(), recordCols.contains("rec_id"), recordCols.contains("data") else { return }
  let hasApp = recordCols.contains("app_id")
  let dateCol = recordCols.contains("delivered_date") ? "delivered_date" : (recordCols.contains("request_date") ? "request_date" : "NULL")
  let sql = "SELECT rec_id, \(hasApp ? "app_id" : "0"), \(dateCol), data FROM record WHERE rec_id > ? ORDER BY rec_id"
  var fresh: [(Int64, Int64, Double?, Data)] = []
  _ = rows(sql, [lastRec]) { s in
    let date: Double? = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : sqlite3_column_double(s, 2)
    let n = Int(sqlite3_column_bytes(s, 3))
    let blob = n > 0 ? Data(bytes: sqlite3_column_blob(s, 3), count: n) : Data()
    fresh.append((sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), date, blob))
  }
  let now = Date().timeIntervalSinceReferenceDate
  for (rec, app, date, blob) in fresh {
    lastRec = max(lastRec, rec)
    seen += 1
    let lag = date.map { String(format: "%.2fs", now - $0) } ?? "n/a"
    guard let top = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any] else {
      say("notif rec=\(rec) app=\(appID(app)) lag=\(lag) data=undecodable(\(blob.count) bytes)")
      continue
    }
    let req = top["req"] as? [String: Any] ?? [:]
    let title = req["titl"] as? String ?? ""
    let sub = req["subt"] as? String ?? ""
    let body = req["body"] as? String ?? ""
    let bundle = top["app"] as? String ?? appID(app)
    var line = "notif rec=\(rec) app=\(bundle) lag=\(lag) title=\(title.count)ch subtitle=\(sub.count)ch body=\(body.count)ch"
    if req.isEmpty { line += " keys=\(top.keys.sorted().joined(separator: ","))" }
    if title.hasPrefix(marker) { line += " TEXT title=\"\(title)\" body=\"\(body)\"" }
    say(line)
  }
}

// MARK: Dock badges

var axTrusted = false
var badges: [String: String] = [:]

func dockItems() -> [AXUIElement] {
  guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
  let app = AXUIElementCreateApplication(dock.processIdentifier)
  var kids: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
        let lists = kids as? [AXUIElement] else { return [] }
  var items: [AXUIElement] = []
  for list in lists {
    var sub: CFTypeRef?
    if AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &sub) == .success, let s = sub as? [AXUIElement] {
      items += s
    }
  }
  return items
}

func attr(_ e: AXUIElement, _ name: String) -> String? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
  return v as? String
}

func pollBadges() {
  if !axTrusted {
    axTrusted = AXIsProcessTrusted()
    if !axTrusted { return }
    say("badges: Accessibility works")
  }
  var now: [String: String] = [:]
  let t = Date()
  for item in dockItems() {
    if let title = attr(item, kAXTitleAttribute as String), let label = attr(item, "AXStatusLabel"), !label.isEmpty {
      now[title] = label
    }
  }
  if now != badges {
    say("badges: " + (now.isEmpty ? "none" : now.keys.sorted().map { "\($0)=\(now[$0]!)" }.joined(separator: " ")) +
        String(format: " (read in %.0f ms)", Date().timeIntervalSince(t) * 1000))
    badges = now
  }
}

// MARK: run

say("start: run \(Int(duration))s, pid \(getpid()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
// Shows the system prompt that adds this app to the Accessibility list (switched off until Penn turns it on).
axTrusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
say("badges: Accessibility \(axTrusted ? "works" : "not granted yet")")
if !openStore() { say("store: no access yet (needs Full Disk Access); retrying every 2 s") }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let started = Date()
var lastStoreTry = Date.distantPast
var lastBeat = Date()
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
  if db != nil { pollStore() } else if Date().timeIntervalSince(lastStoreTry) > 2 {
    lastStoreTry = Date()
    _ = openStore()
  }
}
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
  pollBadges()
  if Date().timeIntervalSince(lastBeat) >= 60 {
    lastBeat = Date()
    say("alive: store=\(db != nil ? "open" : "no access") accessibility=\(axTrusted ? "yes" : "no") notifications=\(seen)")
  }
  if Date().timeIntervalSince(started) >= duration {
    say("end: notifications=\(seen) store=\(db != nil ? "open" : "no access") accessibility=\(axTrusted ? "yes" : "no")")
    exit(0)
  }
}
app.run()
