import AppKit
import SwiftUI

struct Status: Decodable {
    let state: String
    let title: String
    let detail: String
    let progress: Double?
}

@MainActor
final class Launcher: ObservableObject {
    @Published var status = Status(state: "checking", title: "Minecraft on your Mac", detail: "Checking installation…", progress: nil)
    @Published var running = false
    private var process: Process?
    private var buffer = Data()
    let root: URL

    init() {
        let path = Bundle.main.object(forInfoDictionaryKey: "BedrockProjectPath") as? String ?? ""
        root = path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bedrock for Mac") : URL(fileURLWithPath: path)
        start(check: true)
    }

    func start(check: Bool = false, signOut: Bool = false) {
        guard !running else { return }
        running = true
        buffer = Data()
        let task = Process()
        let pipe = Pipe()
        let resources = Bundle.main.resourceURL!
        let worker = resources.appendingPathComponent("worker/BedrockWorker")
        let packaged = FileManager.default.isExecutableFile(atPath: worker.path)
        task.executableURL = packaged ? worker : URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = (packaged ? [] : [root.appendingPathComponent("launcher/setup.py").path]) + (check ? ["--status"] : signOut ? ["--sign-out"] : [])
        task.currentDirectoryURL = packaged ? resources : root
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if packaged { env["BEDROCK_BUNDLE"] = resources.path }
        task.environment = env
        do {
            process = task
            if !check { status = Status(state: "busy", title: "Getting ready", detail: "Checking your Mac…", progress: nil) }
            try task.run()
            // Drain stdout before finishing the run. A timed delay can lose the
            // last status or let a previous worker overwrite a new attempt.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let reader = pipe.fileHandleForReading
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.process === task else { return }
                        self.receive(data)
                    }
                }
                try? reader.close()
                task.waitUntilExit()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.process === task else { return }
                    if !self.buffer.isEmpty { self.receive(Data([10])) }
                    self.running = false
                    self.process = nil
                    if task.terminationStatus != 0 && self.status.state != "error" {
                        self.status = Status(state: "error", title: "Couldn’t finish setup", detail: "Try again. If it happens again, open the setup log.", progress: nil)
                    } else if ["busy", "checking", "playing", "cancelling"].contains(self.status.state) {
                        self.status = Status(state: "error", title: "Setup stopped", detail: "Try again to continue.", progress: nil)
                    }
                }
            }
        } catch {
            running = false
            process = nil
            status = Status(state: "error", title: "Couldn’t start setup", detail: error.localizedDescription, progress: nil)
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            if let next = try? JSONDecoder().decode(Status.self, from: line) { status = next }
            buffer.removeSubrange(...end)
        }
    }

    var canCancel: Bool { running && status.state == "busy" }

    func cancel() {
        guard canCancel else { return }
        status = Status(state: "cancelling", title: "Stopping setup", detail: "Keeping your existing game and saves.", progress: nil)
        process?.terminate()
    }

    func signOut() {
        guard !running else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of Microsoft?"
        alert.informativeText = "Your game and worlds will stay on this Mac. You can sign in with another account next time you play."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign Out")
        if alert.runModal() == .alertSecondButtonReturn { start(signOut: true) }
    }

    func showLog() {
        NSWorkspace.shared.open(root.appendingPathComponent("logs/standalone"))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: Launcher?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard launcher?.running == true else { return .terminateNow }
        let alert = NSAlert()
        if launcher?.canCancel == true {
            alert.messageText = "Stop setup?"
            alert.informativeText = "You can continue later. Your game and saves will be kept."
            alert.addButton(withTitle: "Keep Going")
            alert.addButton(withTitle: "Stop Setup")
            if alert.runModal() == .alertSecondButtonReturn { launcher?.cancel() }
        } else {
            alert.messageText = "Minecraft is still running"
            alert.informativeText = "Quit Minecraft first to finish your session safely. You can close the launcher window while you play."
            alert.addButton(withTitle: "Keep Open")
            alert.runModal()
        }
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct LauncherView: View {
    @ObservedObject var launcher: Launcher
    private var fresh: Bool { launcher.status.state == "new" }
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cube.fill")
                .font(.system(size: 66, weight: .medium))
                .foregroundStyle(.green.gradient)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(launcher.status.title).font(.system(size: 29, weight: .semibold))
                if fresh || !launcher.status.detail.isEmpty {
                    Text(fresh ? "Sign in with the Microsoft account that owns Minecraft for Windows." : launcher.status.detail)
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 365).fixedSize(horizontal: false, vertical: true)
                }
            }
            if launcher.running && launcher.status.state != "playing" {
                VStack(spacing: 10) {
                    if let progress = launcher.status.progress {
                        ProgressView(value: progress).accessibilityLabel("Installation progress")
                    } else { ProgressView().controlSize(.small) }
                }.frame(width: 300)
                if launcher.canCancel {
                    Button("Cancel") { launcher.cancel() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
            } else if !launcher.running {
                Button(launcher.status.state == "error" ? "Try Again" : fresh ? "Install & Play" : launcher.status.state == "cancelled" ? "Continue" : "Play") {
                    launcher.start()
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .controlSize(.large).keyboardShortcut(.defaultAction)
                if fresh {
                    Text("Minecraft downloads after sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if launcher.status.state == "error" {
                Button("Open Setup Log") { launcher.showLog() }.buttonStyle(.link)
            }
        }
        .padding(40).frame(width: 480, height: 390)
    }
}

@main
struct BedrockLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var launcher = Launcher()
    var body: some Scene {
        Window("Bedrock for Mac", id: "launcher") {
            LauncherView(launcher: launcher)
                .onAppear { delegate.launcher = launcher; NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Sign Out of Microsoft…") { launcher.signOut() }
                    .disabled(launcher.running || launcher.status.state == "new")
            }
            CommandGroup(replacing: .help) {
                Button("Bedrock for Mac Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/1JRobertson/bedrock-mac#readme")!)
                }
                Button("Open Setup Logs") { launcher.showLog() }
            }
        }
    }
}
