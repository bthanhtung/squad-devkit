import Cocoa
import Foundation
import UserNotifications

struct Payload: Decodable {
    let title: String
    let body: String
    var subtitle = ""
    var bundle_id = ""
    var app_name = ""
    var backend = ""
    var handle = ""
    var tmux_socket = ""
    var cli_path = ""
    var workspace = ""
    var kitty_listen_on = ""

    enum CodingKeys: String, CodingKey { case title, body, subtitle, bundle_id, app_name, backend, handle, tmux_socket, cli_path, workspace, kitty_listen_on }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        bundle_id = try c.decodeIfPresent(String.self, forKey: .bundle_id) ?? ""
        app_name = try c.decodeIfPresent(String.self, forKey: .app_name) ?? ""
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? ""
        handle = try c.decodeIfPresent(String.self, forKey: .handle) ?? ""
        tmux_socket = try c.decodeIfPresent(String.self, forKey: .tmux_socket) ?? ""
        cli_path = try c.decodeIfPresent(String.self, forKey: .cli_path) ?? ""
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? ""
        kitty_listen_on = try c.decodeIfPresent(String.self, forKey: .kitty_listen_on) ?? ""
    }
}

struct Actions: Encodable {
    let ok = true
    var bundle_id: String
    var app_name: String
    var backend: String
    var commands: [[String]] = []
    var fallback_commands: [[String]] = []
    var warnings: [String] = []
    var handle: String = ""
    var tmux_socket: String = ""
    var cli_path: String = ""
    var workspace: String = ""
    var kitty_listen_on: String = ""

    enum CodingKeys: String, CodingKey { case ok, bundle_id, app_name, backend, commands, fallback_commands, warnings }
    var userInfo: [String: String] {
        ["bundle_id": bundle_id, "app_name": app_name, "backend": backend, "handle": handle,
         "tmux_socket": tmux_socket, "cli_path": cli_path, "workspace": workspace, "kitty_listen_on": kitty_listen_on]
    }
}

let executables: [String: [String]] = ["orca": ["orca", "orca-dev"], "tmux": ["tmux"],
    "herdr_app": ["herdr-app"], "herdr": ["herdr"], "wezterm": ["wezterm"],
    "kitty": ["kitten"], "iterm": ["osascript"]]
let itermScript = """
on run argv
  set targetID to item 1 of argv
  tell application "iTerm2"
    repeat with aWindow in windows
      repeat with aTab in tabs of aWindow
        repeat with aSession in sessions of aTab
          if unique ID of aSession is targetID then
            select aWindow
            select aTab
            select aSession
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "Session not found"
end run
"""

func resolve(_ fields: [String: String], dryRun: Bool) -> Actions {
    var result = Actions(bundle_id: "", app_name: "", backend: "")
    func validate(_ key: String, _ predicate: (String) -> Bool) -> String {
        let value = fields[key] ?? ""
        guard !value.isEmpty else { return "" }
        guard predicate(value) else { result.warnings.append("Invalid \(key)"); return "" }
        return value
    }
    func matches(_ value: String, _ pattern: String, _ limit: Int) -> Bool {
        value.utf8.count <= limit && value.range(of: pattern, options: .regularExpression) != nil
    }
    func path(_ value: String, _ limit: Int) -> Bool {
        value.utf8.count <= limit && value.hasPrefix("/") && !value.contains("..") &&
            value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    result.bundle_id = validate("bundle_id") { matches($0, "^[A-Za-z0-9._-]+$", 200) }
    result.app_name = validate("app_name") { matches($0, "^[A-Za-z0-9 ._-]+$", 100) && !$0.contains("..") }
    result.backend = validate("backend") { executables[$0] != nil || $0 == "ghostty" || $0 == "app" }
    result.handle = validate("handle") { matches($0, "^[A-Za-z0-9_.:%/@-]+$", 256) && !$0.hasPrefix("-") && !$0.contains("..") }
    result.tmux_socket = validate("tmux_socket") { path($0, 512) }
    result.workspace = validate("workspace") { path($0, 1024) }
    result.kitty_listen_on = validate("kitty_listen_on") {
        matches($0, "^(unix:/[A-Za-z0-9._/@:-]+|tcp:[A-Za-z0-9._:-]+)$", 512) &&
            !$0.contains("..") && $0.rangeOfCharacter(from: .controlCharacters) == nil
    }
    let names = executables[result.backend] ?? []
    let home = NSHomeDirectory()
    var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                       "\(home)/.local/bin", "\(home)/.cargo/bin"]
    switch result.backend {
    case "orca": directories.append("/Applications/Orca.app/Contents/Resources/bin")
    case "wezterm": directories.append("/Applications/WezTerm.app/Contents/MacOS")
    case "kitty": directories.append("/Applications/kitty.app/Contents/MacOS")
    case "herdr_app", "herdr": directories.append("/Applications/Herdr.app/Contents/MacOS")
    default: break
    }
    func safeExecutable(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath().path
        return !["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/",
                 "/var/folders/", "/private/var/folders/"].contains { real.hasPrefix($0) } &&
            FileManager.default.isExecutableFile(atPath: url.path)
    }
    result.cli_path = validate("cli_path") { value in
        let url = URL(fileURLWithPath: value).standardizedFileURL
        let trusted = result.backend == "iterm" ? url.path == "/usr/bin/osascript" :
            names.contains(url.lastPathComponent) && directories.contains(url.deletingLastPathComponent().path)
        return path(value, 512) && trusted && (dryRun || safeExecutable(url))
    }
    if !result.cli_path.isEmpty { result.cli_path = URL(fileURLWithPath: result.cli_path).standardizedFileURL.path }
    if result.cli_path.isEmpty && (fields["cli_path"] ?? "").isEmpty && !names.isEmpty {
        let candidates = result.backend == "iterm" ? ["/usr/bin/osascript"] :
            directories.flatMap { directory in names.map { directory + "/" + $0 } }
        result.cli_path = candidates.first { safeExecutable(URL(fileURLWithPath: $0)) } ?? ""
        if result.cli_path.isEmpty { result.warnings.append("No executable for \(result.backend)") }
    }
    let cli = result.cli_path, handle = result.handle
    if result.backend == "orca", !cli.isEmpty, handle.isEmpty, !result.workspace.isEmpty {
        result.commands = [[cli, "worktree", "activate", "--worktree", "path:\(result.workspace)", "--json"]]
    }
    guard !cli.isEmpty, !handle.isEmpty else { return result }
    switch result.backend {
    case "orca":
        result.commands = [[cli, "terminal", "focus", "--terminal", handle, "--json"]]
        if !result.workspace.isEmpty { result.fallback_commands = [[cli, "worktree", "activate", "--worktree", "path:\(result.workspace)", "--json"]] }
    case "tmux":
        let prefix = [cli] + (result.tmux_socket.isEmpty ? [] : ["-S", result.tmux_socket])
        result.commands = [prefix + ["select-window", "-t", handle], prefix + ["select-pane", "-t", handle]]
    case "herdr_app": result.commands = [[cli, "do", "pane.focus", "--pane", handle]]
    case "herdr": result.commands = [[cli, "pane", "focus", handle]]
    case "wezterm": result.commands = [[cli, "cli", "activate-pane", "--pane-id", handle]]
    case "kitty": result.commands = [[cli, "@"] + (result.kitty_listen_on.isEmpty ? [] : ["--to", result.kitty_listen_on]) + ["focus-window", "--match", "id:\(handle)"]]
    case "iterm": result.commands = [[cli, "-e", itermScript, "--", handle]]
    default: break
    }
    return result
}

func readPayload(_ url: URL) throws -> Payload {
    try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
}
func fields(_ payload: Payload) -> [String: String] {
    ["bundle_id": payload.bundle_id, "app_name": payload.app_name, "backend": payload.backend,
     "handle": payload.handle, "tmux_socket": payload.tmux_socket, "cli_path": payload.cli_path, "workspace": payload.workspace, "kitty_listen_on": payload.kitty_listen_on]
}

if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--dry-run-click" {
    do {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let payload = try readPayload(URL(fileURLWithPath: CommandLine.arguments[2]))
        let data = try JSONEncoder().encode(resolve(fields(payload), dryRun: true))
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        fputs("squad-notifier: invalid payload: \(error)\n", stderr)
        exit(1)
    }
}

func runCommand(_ command: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return false }
    if finished.wait(timeout: .now() + 5) == .timedOut {
        process.terminate()
        return false
    }
    return process.terminationStatus == 0
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var idle: DispatchWorkItem?
    private var pending = 0
    private var activeClicks = 0

    func scheduleIdle(_ seconds: Double) {
        idle?.cancel()
        let task = DispatchWorkItem { NSApp.terminate(nil) }
        idle = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        scheduleIdle(5)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--payload"), index + 1 < CommandLine.arguments.count {
            receive(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        idle?.cancel()
        for url in urls { receive(url) }
        if pending == 0 && activeClicks == 0 { scheduleIdle(1.5) }
    }
    func receive(_ url: URL) {
        idle?.cancel()
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.local/share")
        let spoolDir = URL(fileURLWithPath: dataHome).appendingPathComponent("squad-devkit/notify-spool", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        defer {
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
            if !isSymlink && url.pathExtension == "squadnotify" &&
                url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path == spoolDir &&
                url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == spoolDir {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let payload = try? readPayload(url) else { if pending == 0 && activeClicks == 0 { scheduleIdle(1.5) }; return }
        let actions = resolve(fields(payload), dryRun: false)
        pending += 1
        let center = UNUserNotificationCenter.current()
        let finish = { DispatchQueue.main.async {
            self.pending -= 1
            if self.pending == 0 && self.activeClicks == 0 { self.scheduleIdle(1.5) }
        } }
        let schedule = {
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            if !payload.subtitle.isEmpty { content.subtitle = payload.subtitle }
            content.sound = .default
            content.userInfo = actions.userInfo
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in finish() }
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: schedule()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { schedule() } else { finish() }
                }
            default: finish()
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.idle?.cancel()
            self.activeClicks += 1
            DispatchQueue.global(qos: .userInitiated).async {
                var values: [String: String] = [:]
                for (key, value) in response.notification.request.content.userInfo {
                    if let key = key as? String, let value = value as? String { values[key] = value }
                }
                let actions = resolve(values, dryRun: false)
                for command in actions.commands {
                    let success = runCommand(command)
                    if actions.backend == "orca" && !success {
                        for fallback in actions.fallback_commands { _ = runCommand(fallback) }
                    }
                }
                DispatchQueue.main.async {
                    self.activate(actions) {
                        completionHandler()
                        self.activeClicks = max(0, self.activeClicks - 1)
                        if self.pending == 0 && self.activeClicks == 0 { self.scheduleIdle(0.5) }
                    }
                }
            }
        }
    }
    func activate(_ actions: Actions, completion: @escaping () -> Void) {
        let workspace = NSWorkspace.shared
        var appURL: URL?
        if !actions.bundle_id.isEmpty {
            appURL = workspace.urlForApplication(withBundleIdentifier: actions.bundle_id)
        }
        if appURL == nil && !actions.app_name.isEmpty {
            for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(actions.app_name + ".app")
                if FileManager.default.fileExists(atPath: url.path) { appURL = url; break }
            }
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: actions.bundle_id) {
            _ = app.activate(options: [.activateAllWindows])
        }
        guard let url = appURL else { completion(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
