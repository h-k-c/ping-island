import Combine
import Foundation

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared = PluginRegistry()

    @Published private(set) var installedPlugins: [InstalledPlugin] = []
    let enabledStateChanged = PassthroughSubject<String, Never>()

    private let pluginsDirectoryURL: URL
    private let defaults: UserDefaults
    private let enabledKey = "PluginRegistry.enabled.v1"
    private var watchSource: DispatchSourceFileSystemObject?

    nonisolated static var defaultPluginsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingIsland/Plugins", isDirectory: true)
    }

    nonisolated static var builtInPluginsDirectoryURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/PluginBundles", isDirectory: true)
    }

    init(
        pluginsDirectoryURL: URL = PluginRegistry.defaultPluginsDirectoryURL,
        defaults: UserDefaults = .standard
    ) {
        self.pluginsDirectoryURL = pluginsDirectoryURL
        self.defaults = defaults
    }

    func start() {
        createDirectoryIfNeeded()
        rescan()
        startWatching()
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
    }

    func rescan() {
        var found: [InstalledPlugin] = []

        // Built-in plugins from app bundle
        if let builtInURL = Self.builtInPluginsDirectoryURL,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: builtInURL, includingPropertiesForKeys: nil) {
            found += contents
                .filter { $0.pathExtension == "pingplugin" }
                .compactMap { loadPlugin(at: $0) }
        }

        // User-installed plugins
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
        let path = pluginsDirectoryURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .link, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.rescan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }
}
