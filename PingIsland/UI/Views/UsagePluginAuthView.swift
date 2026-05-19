import SwiftUI
import Security

/// Auth configuration UI for the Usage Monitor plugin.
/// Allows users to enter Claude sessionKey and shows Codex credential status.
struct UsagePluginAuthView: View {

    @State private var sessionKeyInput: String = ""
    @State private var isKeyStored: Bool = false
    @State private var showingInput: Bool = false
    @State private var codexAuthExists: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Claude auth row
            claudeAuthRow
            configDivider()
            // Codex auth row
            codexAuthRow
        }
        .onAppear { refresh() }
    }

    // MARK: - Claude

    private var claudeAuthRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isKeyStored ? "checkmark.circle.fill" : "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isKeyStored ? Color.green : Color.orange)
                    .frame(width: 16)

                Text("Claude Session Key")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)

                Spacer()

                if isKeyStored {
                    Button("重置") {
                        deleteClaudeKey()
                        showingInput = false
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.8))
                } else {
                    Button(showingInput ? "取消" : "设置") {
                        showingInput.toggle()
                        sessionKeyInput = ""
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            if !isKeyStored && !showingInput {
                Text("前往 claude.ai → F12 → Application → Cookies → 复制 sessionKey 的值")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showingInput {
                HStack(spacing: 6) {
                    SecureField("粘贴 sessionKey…", text: $sessionKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                    Button("保存") {
                        saveClaudeKey(sessionKeyInput.trimmingCharacters(in: .whitespaces))
                        showingInput = false
                        sessionKeyInput = ""
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .disabled(sessionKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Codex

    private var codexAuthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: codexAuthExists ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(codexAuthExists ? Color.green : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 凭证")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                if !codexAuthExists {
                    Text("运行 codex login 后自动读取 ~/.codex/auth.json")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Helpers

    private func configDivider() -> some View {
        Divider()
            .background(Color.white.opacity(0.05))
            .padding(.leading, 14)
    }

    private func refresh() {
        isKeyStored = loadClaudeKey() != nil
        codexAuthExists = FileManager.default.fileExists(
            atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
        )
    }

    private func loadClaudeKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      "claudeSessionKey" as CFString,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key.isEmpty ? nil : key
    }

    private func saveClaudeKey(_ key: String) {
        guard !key.isEmpty else { return }
        let data = key.data(using: .utf8)!

        // Delete existing first
        let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                    kSecAttrAccount: "claudeSessionKey" as CFString]
        SecItemDelete(del as CFDictionary)

        let add: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      "claudeSessionKey" as CFString,
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
        isKeyStored = true
    }

    private func deleteClaudeKey() {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrAccount: "claudeSessionKey" as CFString]
        SecItemDelete(query as CFDictionary)
        isKeyStored = false
    }
}
