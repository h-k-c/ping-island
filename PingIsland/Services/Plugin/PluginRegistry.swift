import Combine
import CoreServices
import Foundation

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared = PluginRegistry()

    @Published private(set) var installedPlugins: [InstalledPlugin] = []

    private let pluginsDirectoryURL: URL
    private let includeBuiltInPlugins: Bool
    private var watchSource: DispatchSourceFileSystemObject?
    private var fsEventStream: FSEventStreamRef?
    private static let legacyBuiltInPluginIds: Set<String> = [
        "com.wudanwu.pingisland.claude",
        "com.wudanwu.pingisland.codex",
        "com.wudanwu.pingisland.usage",
        "com.wudanwu.pingisland.procmonitor",
    ]

    nonisolated static var defaultPluginsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Auralink/Plugins", isDirectory: true)
    }

    nonisolated static var legacyPluginsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingIsland/Plugins", isDirectory: true)
    }

    /// Xcode flattens bundled plugin seed contents into Resources/.
    nonisolated static var appBundleResourcesURL: URL? {
        Bundle.main.resourceURL
    }

    init(
        pluginsDirectoryURL: URL = PluginRegistry.defaultPluginsDirectoryURL,
        includeBuiltInPlugins: Bool = false
    ) {
        self.pluginsDirectoryURL = pluginsDirectoryURL
        self.includeBuiltInPlugins = includeBuiltInPlugins
    }

    func start() {
        createDirectoryIfNeeded()
        migrateLegacyPluginsIfNeeded()
        removeLegacyBuiltInPluginBundlesIfNeeded()
        installDefaultPluginSeedsIfNeeded()
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
                .filter { !Self.legacyBuiltInPluginIds.contains($0.manifest.id) }
        }

        installedPlugins = found
    }

    private func installDefaultPluginSeedsIfNeeded() {
        guard
            let resourcesURL = Self.appBundleResourcesURL,
            let contents = try? FileManager.default.contentsOfDirectory(
                at: resourcesURL,
                includingPropertiesForKeys: nil
            )
        else { return }

        let executableURL = resourcesURL.appendingPathComponent("PingIslandPlugin")
        let hasSharedExecutable = FileManager.default.isExecutableFile(atPath: executableURL.path)

        for manifestURL in contents where manifestURL.lastPathComponent.hasSuffix(".manifest.json") {
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
                manifest.isBuiltIn
            else { continue }

            let bundleURL = pluginsDirectoryURL
                .appendingPathComponent("\(manifest.id).pingplugin", isDirectory: true)
            let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
            let destinationManifestURL = contentsURL.appendingPathComponent("manifest.json")

            if let existingData = try? Data(contentsOf: destinationManifestURL),
               let existingManifest = try? JSONDecoder().decode(PluginManifest.self, from: existingData),
               !existingManifest.isBuiltIn {
                continue
            }

            try? FileManager.default.createDirectory(
                at: contentsURL,
                withIntermediateDirectories: true
            )
            try? data.write(to: destinationManifestURL, options: .atomic)

            guard hasSharedExecutable else { continue }
            let destinationExecutableURL = bundleURL.appendingPathComponent(manifest.executable)
            try? FileManager.default.removeItem(at: destinationExecutableURL)
            do {
                try FileManager.default.createSymbolicLink(
                    at: destinationExecutableURL,
                    withDestinationURL: executableURL
                )
            } catch {
                try? FileManager.default.copyItem(at: executableURL, to: destinationExecutableURL)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destinationExecutableURL.path
                )
            }
        }
    }

    private func migrateLegacyPluginsIfNeeded() {
        let legacyURL = Self.legacyPluginsDirectoryURL
        guard legacyURL != pluginsDirectoryURL,
              FileManager.default.fileExists(atPath: legacyURL.path),
              let legacyContents = try? FileManager.default.contentsOfDirectory(
                at: legacyURL,
                includingPropertiesForKeys: nil
              )
        else { return }

        for itemURL in legacyContents where itemURL.pathExtension == "pingplugin" {
            if let manifest = loadManifest(at: itemURL),
               manifest.isBuiltIn,
               Self.legacyBuiltInPluginIds.contains(manifest.id) {
                continue
            }

            let destinationURL = pluginsDirectoryURL.appendingPathComponent(
                itemURL.lastPathComponent,
                isDirectory: true
            )
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else { continue }
            try? FileManager.default.copyItem(at: itemURL, to: destinationURL)
        }
    }

    private func removeLegacyBuiltInPluginBundlesIfNeeded() {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: pluginsDirectoryURL,
                includingPropertiesForKeys: nil
            )
        else { return }

        for bundleURL in contents where bundleURL.pathExtension == "pingplugin" {
            guard
                let manifest = loadManifest(at: bundleURL),
                manifest.isBuiltIn,
                Self.legacyBuiltInPluginIds.contains(manifest.id)
            else { continue }
            try? FileManager.default.removeItem(at: bundleURL)
        }
    }

    private func loadPlugin(at bundleURL: URL) -> InstalledPlugin? {
        guard let manifest = loadManifest(at: bundleURL) else { return nil }
        return InstalledPlugin(manifest: manifest, bundleURL: bundleURL)
    }

    private func loadManifest(at bundleURL: URL) -> PluginManifest? {
        let manifestURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else { return nil }
        return manifest
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
