import Foundation

/// Finds the agent CLIs. Apps opened from Finder get a bare PATH, so this also
/// asks the login shell for the PATH the user sees in Terminal (nvm, bun, etc).
enum CLILocator {
    private static let lock = NSLock()
    private static var shellPath: [String]?

    /// Call once at launch, off the main thread. Safe to skip; lookups still work without it.
    static func warmUp() {
        let path = loginShellPath()
        lock.lock(); shellPath = path; lock.unlock()
    }

    /// Folders to search, in order, without duplicates.
    static var searchPath: [String] {
        let home = NSHomeDirectory()
        lock.lock(); let fromShell = shellPath ?? []; lock.unlock()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin",
                      home + "/.bun/bin", home + "/.volta/bin", home + "/.grok/bin"] + nvmBins(home: home)
        var seen = Set<String>()
        return (fromShell + common + inherited + ["/usr/bin", "/bin"]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func find(_ name: String) -> String? {
        for dir in searchPath {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Environment for child processes. The CLI's own folder goes first so a
    /// `#!/usr/bin/env node` shim finds the node it was installed with.
    static func environment(for executable: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let own = (executable as NSString).deletingLastPathComponent
        env["PATH"] = ([own] + searchPath.filter { $0 != own }).joined(separator: ":")
        return env
    }

    private static func nvmBins(home: String) -> [String] {
        let root = home + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { root + "/" + $0 + "/bin" }
    }

    private static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        let marker = "__CLIHEADS_PATH__"
        task.arguments = ["-l", "-c", "printf '\(marker)%s' \"$PATH\""]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        // A slow or broken shell profile shouldn't hold anything up.
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        if task.isRunning { task.terminate(); return [] }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let range = text.range(of: marker) else { return [] }
        return text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init)
    }
}
