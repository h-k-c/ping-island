// PingIsland/Services/Plugin/PluginHost.swift
import Combine
import Foundation
import os.log

@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    @Published private(set) var processStates: [String: PluginProcessState] = [:]

    private let registry: PluginRegistry
    private let arbiter: PluginSlotArbiter
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "PluginHost")

    private var processes: [String: PluginProcess] = [:]
    private var listenerTasks: [String: [Task<Void, Never>]] = [:]
    private var registryCancellable: AnyCancellable?
    private var enabledStateCancellable: AnyCancellable?
    private var hasStarted = false

    init(registry: PluginRegistry = .shared, arbiter: PluginSlotArbiter = .shared) {
        self.registry = registry
        self.arbiter = arbiter
    }

    var runningProcesses: [PluginProcess] {
        Array(processes.values)
    }

    /// Returns running processes whose manifest subscribes to the given event type.
    func subscribedProcesses(for eventType: String) -> [PluginProcess] {
        processes.values.filter { $0.manifest.subscribesTo.contains(eventType) }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        registry.start()

        // Start all plugins concurrently — each has its own timeout and retry logic
        await withTaskGroup(of: Void.self) { group in
            for plugin in registry.installedPlugins where registry.isEnabled(plugin.id) {
                group.addTask { [weak self] in
                    await self?.startPlugin(plugin)
                }
            }
        }

        registryCancellable = registry.$installedPlugins
            .dropFirst()
            .sink { [weak self] plugins in
                Task { [weak self] in
                    await self?.reconcilePlugins(plugins)
                }
            }

        enabledStateCancellable = registry.enabledStateChanged
            .sink { [weak self] pluginId in
                Task { [weak self] in
                    await self?.handleEnabledStateChange(pluginId)
                }
            }
    }

    func stop() async {
        guard hasStarted else { return }
        hasStarted = false
        registryCancellable = nil
        enabledStateCancellable = nil

        for tasks in listenerTasks.values {
            tasks.forEach { $0.cancel() }
        }
        listenerTasks.removeAll()

        for process in processes.values { await process.stop() }
        processes.removeAll()
        processStates.removeAll()

        registry.stop()
    }

    func sendAction(actionId: String, value: Any? = nil, to pluginId: String) async {
        if let process = processes[pluginId] {
            await process.sendAction(actionId: actionId, value: value)
        }
    }

    /// Push a config value change to a running plugin immediately.
    func notifyConfigUpdate(pluginId: String, key: String, value: Any) async {
        if let process = processes[pluginId] {
            await process.sendConfigUpdate(key: key, value: value)
        }
    }

    private func handleEnabledStateChange(_ pluginId: String) async {
        let isEnabled = registry.isEnabled(pluginId)
        let isRunning = processes[pluginId] != nil

        if isEnabled && !isRunning {
            if let plugin = registry.installedPlugins.first(where: { $0.id == pluginId }) {
                await startPlugin(plugin)
            }
        } else if !isEnabled && isRunning {
            await stopPlugin(pluginId)
        }
    }

    private func startPlugin(_ plugin: InstalledPlugin) async {
        guard processes[plugin.id] == nil else { return }
        if let validationFailureReason = plugin.manifest.validationFailureReason {
            processStates[plugin.id] = .failed(validationFailureReason)
            logger.error("Plugin \(plugin.id, privacy: .public) failed validation: \(validationFailureReason, privacy: .public)")
            return
        }

        let process = PluginProcess(manifest: plugin.manifest, bundleURL: plugin.bundleURL)
        processes[plugin.id] = process

        // Attach stream listeners BEFORE starting the process. Plugins may push
        // island/compact (or notify/expanded) immediately after responding to
        // initialize; if the listener only attaches after start() returns, that
        // first push races the consumer and can be dropped.
        listenerTasks[plugin.id] = makeListenerTasks(for: process)

        logger.info("Starting plugin \(plugin.id, privacy: .public)")
        await process.start()

        let state = await process.state
        processStates[plugin.id] = state
        logger.info("Plugin \(plugin.id, privacy: .public) state: \(String(describing: state), privacy: .public)")
    }

    private func stopPlugin(_ pluginId: String) async {
        listenerTasks[pluginId]?.forEach { $0.cancel() }
        listenerTasks.removeValue(forKey: pluginId)

        if let process = processes[pluginId] {
            await process.stop()
            processes.removeValue(forKey: pluginId)
        }

        processStates.removeValue(forKey: pluginId)
        arbiter.removePlugin(pluginId)
    }

    private func reconcilePlugins(_ plugins: [InstalledPlugin]) async {
        let installedIds = Set(plugins.map(\.id))
        let runningIds = Set(processes.keys)

        for id in runningIds.subtracting(installedIds) {
            await stopPlugin(id)
        }

        for plugin in plugins
            where !runningIds.contains(plugin.id) && registry.isEnabled(plugin.id) {
            await startPlugin(plugin)
        }
    }

    private func makeListenerTasks(for process: PluginProcess) -> [Task<Void, Never>] {
        let arbiter = self.arbiter
        return [
            Task.detached {
                for await update in process.compactUpdates where !Task.isCancelled {
                    await MainActor.run { arbiter.handleCompact(update) }
                }
            },
            Task.detached {
                for await update in process.notifyUpdates where !Task.isCancelled {
                    await MainActor.run { arbiter.handleNotify(update) }
                }
            },
            Task.detached {
                for await update in process.expandedUpdates where !Task.isCancelled {
                    await MainActor.run { arbiter.handleExpanded(update) }
                }
            }
        ]
    }
}
