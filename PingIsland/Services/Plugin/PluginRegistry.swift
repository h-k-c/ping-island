import Combine
import CoreServices
import Foundation

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared = PluginRegistry()

    @Published private(set) var installedPlugins: [InstalledPlugin] = []
    let enabledStateChanged = PassthroughSubject<String, Never>()

    private let pluginsDirectoryURL: URL
    private let defaults: UserDefaults
    private let includeBuiltInPlugins: Bool
    private let enabledKey = "PluginRegistry.enabled.v1"
    private var watchSource: DispatchSourceFileSystemObject?
    private var fsEventStream: FSEventStreamRef?

    nonisolated static var defaultPluginsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingIsland/Plugins", isDirectory: true)
    }

    /// Xcode flattens bundle contents into Resources/, so built-in plugins
    /// have their manifest.json and executable directly in Resources.
    nonisolated static var appBundleResourcesURL: URL? {
        Bundle.main.resourceURL
    }

    init(
        pluginsDirectoryURL: URL = PluginRegistry.defaultPluginsDirectoryURL,
        defaults: UserDefaults = .standard,
        includeBuiltInPlugins: Bool = true
    ) {
        self.pluginsDirectoryURL = pluginsDirectoryURL
        self.defaults = defaults
        self.includeBuiltInPlugins = includeBuiltInPlugins
    }

    func start() {
        createDirectoryIfNeeded()
        rescan()
        startWatching()
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    func rescan() {
        var found: [InstalledPlugin] = []

        // Built-in plugins: Xcode flattens PluginBundles contents into Resources/.
        // Each plugin uses a unique filename: {plugin-id}.manifest.json
        // This avoids filename collisions between multiple built-in plugins.
        if includeBuiltInPlugins,
           let resourcesURL = Self.appBundleResourcesURL,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: resourcesURL, includingPropertiesForKeys: nil) {
            let builtIns = contents
                .filter { $0.lastPathComponent.hasSuffix(".manifest.json") }
                .compactMap { manifestURL -> InstalledPlugin? in
                    guard
                        let data = try? Data(contentsOf: manifestURL),
                        let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
                        manifest.isBuiltIn
                    else { return nil }
                    return InstalledPlugin(manifest: manifest, bundleURL: resourcesURL)
                }
            found.append(contentsOf: builtIns)
        }

        // User-installed plugins (full .pingplugin bundle directories)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectoryURL, includingPropertiesForKeys: nil) {
            found += contents
                .filter { $0.pathExtension == "pingplugin" }
                .compactMap { loadPlugin(at: $0) }
        }

        installedPlugins = found
    }

    func isEnabled(_ pluginId: String) -> Bool {
        if let plugin = installedPlugins.first(where: { $0.id == pluginId }),
           plugin.manifest.isBuiltIn {
            return true
        }
        return enabledMap[pluginId] ?? true
    }

    private func loadPlugin(at bundleURL: URL) -> InstalledPlugin? {
        let manifestURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else { return nil }
        return InstalledPlugin(manifest: manifest, bundleURL: bundleURL)
    }

    func setEnabled(_ enabled: Bool, for pluginId: String) {
        var map = enabledMap
        map[pluginId] = enabled
        defaults.set(map, forKey: enabledKey)
        enabledStateChanged.send(pluginId)
    }

    private var enabledMap: [String: Bool] {
        (defaults.dictionary(forKey: enabledKey) as? [String: Bool]) ?? [:]
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: pluginsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func startWatching() {
        // Use FSEventStream for reliable directory-tree monitoring.
        // DispatchSource.makeFileSystemObjectSource only watches the directory inode
        // and misses sub-bundle additions on some macOS versions.
        let paths = [pluginsDirectoryURL.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let registry = Unmanaged<PluginRegistry>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { registry.rescan() }
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,   // latency: coalesce events within 0.5s
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }
}
