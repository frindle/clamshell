import Foundation

/// A planned restart that skips the disk-unlock screen once: `fdesetup authrestart`.
///
/// It needs root. Nothing here adds a root process or keeps a password: the user name
/// and password arrive for this one call (typed in the menu, sent by a client over its
/// encrypted session, or piped to `clamshell restart`), go to the child's standard
/// input through a pipe, and are dropped when it ends. They are never in argv, in the
/// environment, in a file or in the log.
///
/// The child is `sudo -k -S -p "" fdesetup authrestart -inputplist`. `-S` makes sudo
/// read the password from stdin, one byte at a time and stopping at the newline, so
/// what follows stays in the pipe for `fdesetup -inputplist`, which reads its
/// Username/Password plist from the same stdin. `-k` ignores a cached sudo ticket, or
/// sudo would not read the password line and fdesetup would get it as the plist.
/// (An askpass helper would need a second program or a file on disk; this needs neither.)
enum RestartService {
    enum Outcome: UInt8 {
        case restarting = 0   // fdesetup accepted; the Mac restarts in a moment
        case refused = 1      // sudo or fdesetup said no: almost always a wrong password
        case unsupported = 2  // authrestart is not available on this Mac
        case failed = 3       // could not run it, or the input was not acceptable
    }

    static let sudo = "/usr/bin/sudo"
    static let sudoArguments = ["-k", "-S", "-p", "", "/usr/sbin/fdesetup", "authrestart", "-inputplist"]

    /// What a child process gets and gives back. Swappable for tests.
    struct Runner {
        var supportsAuthRestart: () -> Bool
        /// Runs `executable arguments` with `stdin` on its standard input; returns its exit status.
        var run: (_ executable: String, _ arguments: [String], _ stdin: Data) -> Int32?
    }

    static let system = Runner(
        supportsAuthRestart: {
            guard let out = capture("/usr/bin/fdesetup", ["supportsauthrestart"]) else { return false }
            return out.contains("true")
        },
        run: { executable, arguments, stdin in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        })

    /// True for a user name this will pass on: short, no spaces or control characters.
    static func validUser(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64
            && name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || "._-".unicodeScalars.contains($0)) }
    }

    /// One line cannot hold a newline, and the plist needs XML escaping.
    static func validPassword(_ password: String) -> Bool {
        !password.isEmpty && password.utf8.count <= 256 && !password.contains("\n") && !password.contains("\r")
            && !password.unicodeScalars.contains { $0.value < 0x20 }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `password\n` then the plist for `fdesetup -inputplist`.
    static func stdinPayload(username: String, password: String) -> Data {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Username</key><string>\(escape(username))</string>
            <key>Password</key><string>\(escape(password))</string>
            </dict></plist>

            """
        return Data((password + "\n" + plist).utf8)
    }

    static func restart(username: String, password: String, runner: Runner = system) -> Outcome {
        guard validUser(username), validPassword(password) else { return .failed }
        guard runner.supportsAuthRestart() else { return .unsupported }
        var payload = stdinPayload(username: username, password: password)
        defer { payload.resetBytes(in: 0 ..< payload.count) }
        guard let status = runner.run(sudo, sudoArguments, payload) else { return .failed }
        return status == 0 ? .restarting : .refused
    }

    static func message(_ outcome: Outcome) -> String {
        switch outcome {
        case .restarting: return "Restarting. The disk will not ask to be unlocked this time."
        case .refused: return "The Mac did not accept that user name and password. Nothing was restarted."
        case .unsupported: return "This Mac cannot do an authenticated restart (FileVault must be on and a user must be able to unlock it)."
        case .failed: return "Could not start the restart. Nothing was restarted."
        }
    }

    private static func capture(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - clamshell restart (over SSH or in a terminal)

    /// `clamshell restart`: reads the user name and password from a terminal (no echo) or,
    /// when stdin is a pipe, from one JSON line {"username": ..., "password": ...}.
    static func runCommand() -> Int32 {
        var username = "", password = ""
        if isatty(STDIN_FILENO) != 0 {
            print("User name: ", terminator: "")
            username = readLine() ?? ""
            if let p = getpass("Password: ") { password = String(cString: p) }
        } else if let line = readLine(), let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            username = object["username"] ?? ""
            password = object["password"] ?? ""
        }
        let outcome = restart(username: username, password: password)
        print(message(outcome))
        return outcome == .restarting ? 0 : 1
    }
}
