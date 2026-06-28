// PluginStorage — per-plugin KV store.
// Non-secret values: UserDefaults with namespaced keys.
// Secret values: plain JSON file at ~/Library/Application Support/Auralink/plugin-secrets.json

import Foundation
import Security

@MainActor
final class PluginStorage {
    static let shared = PluginStorage()
    private init() {}

    // MARK: - Secret file storage

    private var secretsFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Auralink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plugin-secrets.json")
    }

    private func loadSecrets() -> [String: String] {
        guard let data = try? Data(contentsOf: secretsFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveSecrets(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: secretsFileURL, options: .atomic)
    }

    // MARK: - Public API

    func get(pluginId: String, key: String) -> Any? {
        let ns = namespacedKey(pluginId: pluginId, key: key)
        return UserDefaults.standard.object(forKey: ns)
    }

    func set(pluginId: String, key: String, value: Any?) {
        let ns = namespacedKey(pluginId: pluginId, key: key)
        if let value {
            UserDefaults.standard.set(value, forKey: ns)
        } else {
            UserDefaults.standard.removeObject(forKey: ns)
        }
    }

    func delete(pluginId: String, key: String) {
        let ns = namespacedKey(pluginId: pluginId, key: key)
        UserDefaults.standard.removeObject(forKey: ns)
    }

    // MARK: - Secret (plain file, with one-time keychain migration)

    func getSecret(pluginId: String, key: String) -> String? {
        let accountKey = namespacedKey(pluginId: pluginId, key: key)
        var secrets = loadSecrets()
        if let value = secrets[accountKey], !value.isEmpty { return value }

        // One-time migration: read from legacy keychain and save to file
        if let legacy = legacyKeychainRead(key: key) {
            secrets[accountKey] = legacy
            saveSecrets(secrets)
            return legacy
        }
        return nil
    }

    private func legacyKeychainRead(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  "com.claude-monitor.app" as CFString,
            kSecAttrAccount:  key as CFString,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8), !str.isEmpty
        else { return nil }
        return str
    }

    func setSecret(pluginId: String, key: String, value: String) {
        let accountKey = namespacedKey(pluginId: pluginId, key: key)
        var secrets = loadSecrets()
        secrets[accountKey] = value
        saveSecrets(secrets)
    }

    func deleteSecret(pluginId: String, key: String) {
        let accountKey = namespacedKey(pluginId: pluginId, key: key)
        var secrets = loadSecrets()
        secrets.removeValue(forKey: accountKey)
        saveSecrets(secrets)
    }

    // MARK: - Bulk read for initialize injection

    /// Returns all stored config values for a plugin as a [key: value] dict.
    /// Secrets are decrypted and included. This is injected into initialize params.
    func allConfig(for plugin: InstalledPlugin) -> [String: Any] {
        var result: [String: Any] = [:]
        for item in plugin.manifest.configItems {
            let value: Any?
            switch item.type {
            case .secret:
                value = getSecret(pluginId: plugin.id, key: item.key)
            case .toggle:
                let ns = namespacedKey(pluginId: plugin.id, key: item.key)
                if UserDefaults.standard.object(forKey: ns) != nil {
                    value = UserDefaults.standard.bool(forKey: ns)
                } else if let def = item.defaultValue {
                    value = def == "true"
                } else {
                    value = false
                }
            case .number:
                let ns = namespacedKey(pluginId: plugin.id, key: item.key)
                if let stored = UserDefaults.standard.object(forKey: ns) as? Double {
                    value = stored
                } else if let def = item.defaultValue, let d = Double(def) {
                    value = d
                } else {
                    value = nil
                }
            default:
                let ns = namespacedKey(pluginId: plugin.id, key: item.key)
                let stored = UserDefaults.standard.string(forKey: ns)
                value = stored ?? item.defaultValue
            }
            if let value { result[item.key] = value }
        }
        return result
    }

    // MARK: - Private

    private func namespacedKey(pluginId: String, key: String) -> String {
        "\(pluginId).\(key)"
    }

}
