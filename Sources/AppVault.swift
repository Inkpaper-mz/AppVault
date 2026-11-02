import SwiftUI
import AppKit
import LocalAuthentication
import UniformTypeIdentifiers

// MARK: - 配置条目

struct VaultEntry: Codable, Identifiable {
    var path: String

    var id: String { path }

    var displayName: String {
        let base = (path as NSString).lastPathComponent
        return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
    }

    /// 上锁时应用会被改名为 ".Name.app"，点号开头，Spotlight 与访达都不再显示。
    var hiddenPath: String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent).path
    }

    var exists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path) || fm.fileExists(atPath: hiddenPath)
    }
}

// MARK: - 状态模型

@MainActor
final class VaultModel: ObservableObject {
    static let shared = VaultModel()

    @Published var entries: [VaultEntry] = []
    @Published var unlocked = false
    @Published var busy = false
    @Published var needsPermission = false
    @Published var message = ""

    private let fm = FileManager.default
    private var savedModes: [String: Int] = [:]
    private var relaunchAfterUnlock: Set<String> = []

    private var supportDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppVault", isDirectory: true)
    }
    private var configURL: URL { supportDir.appendingPathComponent("config.json") }
    private var stateURL: URL { supportDir.appendingPathComponent("state.json") }

    init() {
        reload()
        refreshState()
    }

    // MARK: 配置

    func reload() {
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: configURL),
           let list = try? JSONDecoder().decode([VaultEntry].self, from: data),
           !list.isEmpty {
            entries = list
        } else {
            let defaults = ["/Applications/Clash for Windows.app", "/Applications/ChatGPT.app"]
                .filter { fm.fileExists(atPath: $0) }
                .map { VaultEntry(path: $0) }
            entries = defaults
            saveConfig()
        }

        if let data = try? Data(contentsOf: stateURL),
           let modes = try? JSONDecoder().decode([String: Int].self, from: data) {
            savedModes = modes
        }
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: configURL)
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(savedModes) {
            try? data.write(to: stateURL)
        }
    }

    // MARK: 系统调用

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("run failed: \(tool) \(args.joined(separator: " ")) — \(error)")
            return false
        }
        process.waitUntilExit()
        let ok = process.terminationStatus == 0
        log("\(tool) \(args.joined(separator: " ")) -> \(ok ? "ok" : "status \(process.terminationStatus)")")
        return ok
    }

    private func log(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AppVault.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func currentMode(of path: String) -> Int? {
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let number = attributes[.posixPermissions] as? NSNumber else { return nil }
        return number.intValue
    }

    private func terminateRunning(at bundlePath: String) {
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let executable = app.executableURL?.path else { return false }
            return executable == bundlePath || executable.hasPrefix(bundlePath + "/")
        }
        if !running.isEmpty {
            relaunchAfterUnlock.insert(bundlePath)
            running.forEach { $0.terminate() }
            log("terminate \(bundlePath): \(running.count) process(es)")
        }
    }

    // MARK: 状态

    func refreshState() {
        let visible = entries.contains { entry in
            fm.fileExists(atPath: entry.path)
        }
        unlocked = visible
        message = visible ? "当前：应用可见" : "当前：应用已隐藏"
    }

    // MARK: 上锁 / 解锁

    func lockAll() {
        needsPermission = false
        var failures: [String] = []

        for entry in entries where entry.exists {
            let original = entry.path
            let hidden = entry.hiddenPath

            if let mode = currentMode(of: original), mode != 0o000 {
                savedModes[original] = mode
            }

            terminateRunning(at: original)

            // 先在原路径上断权限：改名后的路径会被 TCC 当成新 App 而拒绝修改。
            if fm.fileExists(atPath: original) {
                if !run("/usr/bin/chflags", ["hidden", original]) {
                    failures.append("隐藏 \(entry.displayName)")
                }
                if !run("/bin/chmod", ["000", original]) {
                    failures.append("锁定 \(entry.displayName)")
                }
                do {
                    try fm.moveItem(atPath: original, toPath: hidden)
                    log("rename \(original) -> \(hidden)")
                } catch {
                    failures.append("改名 \(entry.displayName)")
                    log("rename failed: \(error)")
                }
            } else if fm.fileExists(atPath: hidden) {
                _ = run("/usr/bin/chflags", ["hidden", hidden])
                _ = run("/bin/chmod", ["000", hidden])
            }
        }

        saveState()
        unlocked = false

        if failures.isEmpty {
            message = "已上锁 · 搜不到、看不到、打不开"
        } else {
            needsPermission = true
            message = "有 \(failures.count) 项被系统拒绝，需要授权「App 管理」后重试"
        }
    }

    func unlockAll() {
        needsPermission = false
        var failures: [String] = []

        for entry in entries where entry.exists {
            let original = entry.path
            let hidden = entry.hiddenPath
            let mode = savedModes[original] ?? 0o755

            if fm.fileExists(atPath: hidden) {
                do {
                    try fm.moveItem(atPath: hidden, toPath: original)
                    log("rename \(hidden) -> \(original)")
                } catch {
                    failures.append("恢复名称 \(entry.displayName)")
                    log("rename back failed: \(error)")
                }
            }

            // 改回原路径后再恢复权限，顺序与上锁相反。
            if !restorePermissions(at: original, mode: mode) {
                failures.append("恢复 \(entry.displayName)")
            }
            _ = run("/usr/bin/mdimport", [original])
        }

        relaunchAfterUnlock.removeAll()
        unlocked = true

        if failures.isEmpty {
            message = "已解锁 · 应用已恢复可见"
        } else {
            needsPermission = true
            message = "部分操作失败，可能需要在「App 管理」中授权"
        }
    }

    @discardableResult
    private func restorePermissions(at path: String, mode: Int) -> Bool {
        for _ in 0..<3 {
            _ = run("/bin/chmod", [String(mode, radix: 8), path])
            _ = run("/usr/bin/chflags", ["nohidden", path])
            if currentMode(of: path) != 0o000 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // MARK: 列表维护

    func addApp(at url: URL) {
        let path = url.path
        guard path.hasSuffix(".app"), !entries.contains(where: { $0.path == path }) else { return }
        entries.append(VaultEntry(path: path))
        saveConfig()
        refreshState()
        message = "已添加 \(VaultEntry(path: path).displayName)"
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择要放进保险箱的应用"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            panel.urls.forEach { addApp(at: $0) }
        }
    }

    func confirmRemove(_ entry: VaultEntry) {
        let alert = NSAlert()
        alert.messageText = "从保险箱移除「\(entry.displayName)」？"
        alert.informativeText = "只是从列表里移除，不会删除 App 本身。若它正被隐藏，会先恢复显示。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移除")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        removeApp(entry)
    }

    func removeApp(_ entry: VaultEntry) {
        // 还处于隐藏状态时先恢复；恢复不了就保留在列表里，避免应用被永久藏起来。
        guard restoreIfHidden(entry) else {
            message = "移除失败：\(entry.displayName) 仍在隐藏状态，请先点「验证并解锁」再移除"
            return
        }
        entries.removeAll { $0.id == entry.id }
        saveConfig()
        refreshState()
        message = "已从列表移除 \(entry.displayName)"
    }

    private func restoreIfHidden(_ entry: VaultEntry) -> Bool {
        let original = entry.path
        let hidden = entry.hiddenPath
        guard fm.fileExists(atPath: hidden), !fm.fileExists(atPath: original) else { return true }

        do {
            try fm.moveItem(atPath: hidden, toPath: original)
        } catch {
            log("restore on remove failed: \(error)")
            return false
        }

        let mode = savedModes[original] ?? 0o755
        let restored = restorePermissions(at: original, mode: mode)
        _ = run("/usr/bin/mdimport", [original])
        log("restore on remove \(original) -> \(restored ? "ok" : "permission denied")")

        guard restored else {
            // 回滚到隐藏状态，保持状态一致
            _ = run("/usr/bin/chflags", ["hidden", original])
            _ = run("/bin/chmod", ["000", original])
            try? fm.moveItem(atPath: original, toPath: hidden)
            return false
        }
        return true
    }

    func openAppManagementSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 身份验证

    func authenticateAndUnlock() async {
        busy = true
        defer { busy = false }

        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "使用登录密码"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "此设备无法进行身份验证，请先在系统中设置 Touch ID 或登录密码"
            return
        }

        let granted: Bool = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "验证身份后显示被隐藏的应用") { success, _ in
                continuation.resume(returning: success)
            }
        }

        if granted {
            unlockAll()
        } else {
            message = "验证未通过，应用保持隐藏"
        }
    }
}

// MARK: - 界面

struct ContentView: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: model.unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(model.unlocked ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用保险箱")
                        .font(.title2.bold())
                    Text(model.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(model.entries) { entry in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName).fontWeight(.medium)
                            Text(entry.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(statusText(for: entry))
                            .font(.caption.bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(statusColor(for: entry).opacity(0.16)))
                            .foregroundStyle(statusColor(for: entry))

                        Button {
                            model.confirmRemove(entry)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("从保险箱移除（会先恢复显示）")
                    }
                }
            }

            if model.needsPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("系统阻止了修改。请在「隐私与安全性 › App 管理」中勾选「应用保险箱」。")
                        .font(.caption)
                    Spacer()
                    Button("打开设置") { model.openAppManagementSettings() }
                        .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            Divider()

            HStack {
                Button(model.unlocked ? "重新上锁" : "验证并解锁") {
                    if model.unlocked {
                        model.lockAll()
                    } else {
                        Task { await model.authenticateAndUnlock() }
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)

                Spacer()

                Button("添加应用…") {
                    model.presentAddPanel()
                }
                .disabled(model.busy)

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }

            Text("解锁需要 Touch ID 或登录密码。上锁会退出这些 App 并改名为点号开头；解锁只恢复图标和权限，不会自动启动它们。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 540)
    }

    private func statusText(for entry: VaultEntry) -> String {
        guard entry.exists else { return "未找到" }
        return model.unlocked ? "可见" : "已隐藏"
    }

    private func statusColor(for entry: VaultEntry) -> Color {
        guard entry.exists else { return .gray }
        return model.unlocked ? .green : .orange
    }
}

// MARK: - 应用入口

@main
struct AppVaultApp: App {
    @StateObject private var model = VaultModel.shared

    var body: some Scene {
        WindowGroup("应用保险箱") {
            ContentView(model: model)
                .onAppear { model.refreshState() }
        }

        MenuBarExtra("应用保险箱", systemImage: "lock.shield") {
            Button("打开窗口") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("上锁") { model.lockAll() }
            Button("验证并解锁…") {
                Task { await model.authenticateAndUnlock() }
            }
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
    }
}
