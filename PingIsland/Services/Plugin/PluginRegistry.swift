import Combine
import Foundation

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared = PluginRegistry()

    @Published private(set) var installedPlugins: [InstalledPlugin] = []

    private let pluginsDirectoryURL: URL
    private let defaults: UserDefaults
    private let enabledKey = "PluginRegistry.enabled.v1"
    private var watchSource: DispatchSourceFileSystemObject?

    nonisolated static var defaultPluginsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingIsland/Plugins", isDirectory: true)
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
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: pluginsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            installedPlugins = []
            return
        }

        installedPlugins = contents
            .filter { $0.pathExtension == "pingplugin" }
            .compactMap { bundleURL -> InstalledPlugin? in
                let manifestURL = bundleURL
                    .appendingPathComponent("Contents")
                    .appendingPathComponent("manifest.json")
                guard
                    let data = try? Data(contentsOf: manifestURL),
                    let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
                else { return nil }
                return InstalledPlugin(manifest: manifest, bundleURL: bundleURL)
            }
    }

    func isEnabled(_ pluginId: String) -> Bool {
        enabledMap[pluginId] ?? true
    }

    func setEnabled(_ enabled: Bool, for pluginId: String) {
        var map = enabledMap
        map[pluginId] = enabled
        defaults.set(map, forKey: enabledKey)
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
