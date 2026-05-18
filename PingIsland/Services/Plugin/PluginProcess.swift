import Foundation
import os.log

actor PluginProcess {
    let manifest: PluginManifest
    nonisolated let compactUpdates: AsyncStream<PluginCompactUpdate>
    nonisolated let notifyUpdates: AsyncStream<PluginNotifyUpdate>
    nonisolated let expandedUpdates: AsyncStream<PluginExpandedUpdate>

    private(set) var state: PluginProcessState = .stopped

    private let bundleURL: URL
    private let islandVersion: String
    private let initializeTimeoutSeconds: Double
    private let logger: Logger

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var retryCount = 0
    private static let maxRetries = 3
    private static let retryDelaysNanos: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

    private var readyContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    private let compactCont: AsyncStream<PluginCompactUpdate>.Continuation
    private let notifyCont: AsyncStream<PluginNotifyUpdate>.Continuation
    private let expandedCont: AsyncStream<PluginExpandedUpdate>.Continuation

    init(
        manifest: PluginManifest,
        bundleURL: URL,
        islandVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        initializeTimeoutSeconds: Double = 5.0
    ) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.islandVersion = islandVersion
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Plugin")

        var cc: AsyncStream<PluginCompactUpdate>.Continuation!
        var nc: AsyncStream<PluginNotifyUpdate>.Continuation!
        var ec: AsyncStream<PluginExpandedUpdate>.Continuation!

        compactUpdates = AsyncStream { cc = $0 }
        notifyUpdates = AsyncStream { nc = $0 }
        expandedUpdates = AsyncStream { ec = $0 }
        compactCont = cc
        notifyCont = nc
        expandedCont = ec
    }

    func start() async {
        guard state == .stopped else { return }
        await launchWithRetry()
    }

    func stop() {
        timeoutTask?.cancel()
        readTask?.cancel()
        readyContinuation?.resume(returning: false)
        readyContinuation = nil
        sendRawMessage(["jsonrpc": "2.0", "method": "shutdown"])
        let proc = process
        Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if proc?.isRunning == true { proc?.terminate() }
        }
        process = nil
        stdinHandle = nil
        state = .stopped
    }

    func sendAction(actionId: String) {
        sendRawMessage(["jsonrpc": "2.0", "method": "action", "params": ["actionId": actionId]])
    }

    private func launchWithRetry() async {
        let success = await launch()
        guard !success, retryCount < Self.maxRetries else { return }
        let delay = Self.retryDelaysNanos[min(retryCount, Self.retryDelaysNanos.count - 1)]
        retryCount += 1
        try? await Task.sleep(nanoseconds: delay)
        await launchWithRetry()
    }

    private func launch() async -> Bool {
        state = .starting

        let execURL = bundleURL.appendingPathComponent(manifest.executable)
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            state = .failed("Executable not found: \(execURL.lastPathComponent)")
            return false
        }

        let proc = Process()
        proc.executableURL = execURL
        proc.currentDirectoryURL = bundleURL.appendingPathComponent("Contents")
        proc.environment = Foundation.ProcessInfo.processInfo.environment.merging([
            "PING_ISLAND_VERSION": islandVersion,
            "PING_ISLAND_PLUGIN_ID": manifest.id
        ]) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() } catch {
            state = .failed("Process launch error: \(error.localizedDescription)")
            return false
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        startStdoutReader(stdoutPipe.fileHandleForReading)
        forwardStderr(stderrPipe.fileHandleForReading)

        sendRawMessage([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["islandVersion": islandVersion, "pluginId": manifest.id, "config": [:] as [String: Any]]
        ])

        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            readyContinuation = cont
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(initializeTimeoutSeconds * 1_000_000_000))
                await timeoutFired()
            }
        }

        timeoutTask?.cancel()
        timeoutTask = nil

        if ready {
            state = .ready
            retryCount = 0
        } else {
            proc.terminate()
            state = .failed("Initialize timeout after \(initializeTimeoutSeconds)s")
        }
        return ready
    }

    private func timeoutFired() {
        if let c = readyContinuation {
            readyContinuation = nil
            c.resume(returning: false)
        }
    }

    private func startStdoutReader(_ handle: FileHandle) {
        readTask = Task {
            var buffer = Data()
            do {
                for try await byte in handle.bytes {
                    if byte == UInt8(ascii: "\n") {
                        if !buffer.isEmpty {
                            await processLine(Data(buffer))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        buffer.append(byte)
                    }
                }
            } catch { }
        }
    }

    private func forwardStderr(_ handle: FileHandle) {
        let pluginId = manifest.id
        Task.detached(priority: .background) {
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ping-island-debug/plugins")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logURL = logDir.appendingPathComponent("\(pluginId).log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? Data().write(to: logURL)
            }
            guard let writer = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? writer.close() }
            try? writer.seekToEnd()
            do {
                for try await byte in handle.bytes {
                    try? writer.write(contentsOf: Data([byte]))
                }
            } catch { }
        }
    }

    private func processLine(_ data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["id"] != nil, let result = json["result"] as? [String: Any] {
            let ready = result["ready"] as? Bool ?? false
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(returning: ready)
            }
            return
        }

        guard let method = json["method"] as? String else { return }
        guard let params = json["params"],
              let paramsData = try? JSONSerialization.data(withJSONObject: params) else { return }

        let decoder = JSONDecoder()

        switch method {
        case "island/compact":
            struct Params: Decodable {
                let position: CompactPosition
                let content: PluginCompactContent?
            }
            if let p = try? decoder.decode(Params.self, from: paramsData) {
                compactCont.yield(PluginCompactUpdate(
                    pluginId: manifest.id,
                    position: p.position,
                    content: p.content
                ))
            }

        case "island/notify":
            if let content = try? decoder.decode(PluginNotifyContent.self, from: paramsData) {
                notifyCont.yield(PluginNotifyUpdate(pluginId: manifest.id, content: content))
            }

        case "island/expanded":
            struct Params: Decodable { let sections: [ExpandedSection] }
            if let p = try? decoder.decode(Params.self, from: paramsData) {
                expandedCont.yield(PluginExpandedUpdate(pluginId: manifest.id, sections: p.sections))
            }

        default:
            logger.debug("Unknown method from plugin \(self.manifest.id, privacy: .public): \(method, privacy: .public)")
        }
    }

    private func sendRawMessage(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let handle = stdinHandle else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        try? handle.write(contentsOf: line)
    }
}
