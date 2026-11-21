// E7 probe: can a host agent read new notifications and Dock badges on this Mac, and how fast?
// Two paths for notifications: the store (Full Disk Access, about 5 s late) and the on-screen
// banner (Accessibility).
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
// rec_id is a plain rowid, so clearing history lets new rows reuse ids below lastRec.
// The delivery time is the second watermark; seenKeys stops a row being logged twice.
var lastDate: Double = 0
var seenKeys: Set<String> = []
var dateCol = "NULL"
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
  dateCol = recordCols.contains("delivered_date") ? "delivered_date" : (recordCols.contains("request_date") ? "request_date" : "NULL")
  var count: Int64 = 0
  _ = rows("SELECT count(*), coalesce(max(rec_id), 0), coalesce(max(\(dateCol)), 0) FROM record") {
    count = sqlite3_column_int64($0, 0); lastRec = sqlite3_column_int64($0, 1); lastDate = sqlite3_column_double($0, 2)
  }
  say("store: \(count) rows; watching for rec_id > \(lastRec) or \(dateCol) > \(lastDate)")
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
  let byDate = dateCol == "NULL" ? "" : " OR \(dateCol) > \(lastDate)"
  let sql = "SELECT rec_id, \(hasApp ? "app_id" : "0"), \(dateCol), data FROM record WHERE rec_id > ?\(byDate) ORDER BY rec_id"
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
    if let d = date { lastDate = max(lastDate, d) }
    guard seenKeys.insert("\(rec)@\(date ?? 0)").inserted else { continue }
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
    if title.hasPrefix(marker) {
      let delivered = date.map { stamp.string(from: Date(timeIntervalSinceReferenceDate: $0)) } ?? "n/a"
      line += " delivered=\(delivered) TEXT title=\"\(title)\" body=\"\(body)\""
    }
    say(line)
  }
}

// MARK: banners (Accessibility)
//
// The store is written about 5 s after delivery. The banner is on screen at once, as part of the
// Notification Center process, so reading its text through Accessibility should be much faster.
// Shown only when the banner is: Focus, Do Not Disturb or the "None" style hide it.

var ncPid: pid_t = 0
var ncObserver: AXObserver?
var bannerTexts: Set<String> = []

func collectTexts(_ e: AXUIElement, depth: Int, into out: inout [String]) {
  guard depth < 14, out.count < 300 else { return }
  for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let s = v as? String, !s.isEmpty { out.append(s) }
  }
  var kids: CFTypeRef?
  if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let ks = kids as? [AXUIElement] {
    for k in ks { collectTexts(k, depth: depth + 1, into: &out) }
  }
}

func scanBanners(_ why: String) {
  guard axTrusted else { return }
  if ncPid == 0 || NSRunningApplication(processIdentifier: ncPid) == nil { attachNotificationCenter() }
  guard ncPid != 0 else { return }
  let t = Date()
  var out: [String] = []
  collectTexts(AXUIElementCreateApplication(ncPid), depth: 0, into: &out)
  let now = Set(out)
  let fresh = now.subtracting(bannerTexts)
  bannerTexts = now
  guard !fresh.isEmpty else { return }
  var line = "banner(\(why)): \(fresh.count) new text(s), lengths=\(fresh.map { $0.count }.sorted())"
    + String(format: " walk=%.0f ms", Date().timeIntervalSince(t) * 1000)
  let marked = fresh.filter { $0.contains(marker) }.sorted()
  if !marked.isEmpty { line += " TEXT " + marked.map { "\"\($0)\"" }.joined(separator: " ") }
  say(line)
}

func attachNotificationCenter() {
  guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
    return
  }
  ncPid = nc.processIdentifier
  var obs: AXObserver?
  guard AXObserverCreate(ncPid, { _, _, note, _ in scanBanners(note as String) }, &obs) == .success, let o = obs else {
    say("banners: observer could not be made")
    return
  }
  let app = AXUIElementCreateApplication(ncPid)
  var results: [String] = []
  for n in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification] {
    results.append("\(n)=\(AXObserverAddNotification(o, app, n as CFString, nil).rawValue)")
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
  ncObserver = o
  say("banners: watching Notification Center pid \(ncPid) (\(results.joined(separator: " ")); 0 is success)")
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
  // The observer should see a banner first; the poll shows how much it gains.
  scanBanners("poll")
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
