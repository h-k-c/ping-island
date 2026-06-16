// ClipboardShelfPlugin - in-memory clipboard shelf island tool.
// Polls NSPasteboard, keeps recent previews only, and never writes clipboard data to disk.

import AppKit
import Foundation

enum ClipboardShelfPlugin {
    private static let pollInterval: TimeInterval = 1.8
    private static let maxStoredEntries = 20
    private static let maxExpandedEntries = 5
    private static let maxPreviewCharacters = 120

    private static var refreshTimer: DispatchSourceTimer?
    private static var lastChangeCount = NSPasteboard.general.changeCount
    private static var entries: [ClipboardShelfEntry] = []

    static func run() {
        guard let initialMessage = readLine() else { return }
        handleInitialize(initialMessage)

        refreshFromPasteboard(force: true)
        schedulePolling()

        DispatchQueue.global(qos: .utility).async {
            while let msg = readLine() {
                handleMessage(msg)
            }
            exit(0)
        }

        dispatchMain()
    }

    private static func handleInitialize(_ msg: [String: Any]) {
        let id = msg["id"] ?? 1
        sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": ["name": "Clipboard Shelf", "ready": true]
        ])
    }

    private static func handleMessage(_ msg: [String: Any]) {
        switch msg["method"] as? String {
        case "shutdown":
            DispatchQueue.main.async {
                refreshTimer?.cancel()
                refreshTimer = nil
                exit(0)
            }
        case "action":
            let actionId = (msg["params"] as? [String: Any])?["actionId"] as? String
            if actionId == "clear" {
                DispatchQueue.main.async { clearShelf() }
            }
        default:
            break
        }
    }

    private static func schedulePolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler {
            refreshFromPasteboard(force: false)
        }
        refreshTimer = timer
        timer.resume()
    }

    private static func refreshFromPasteboard(force: Bool) {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard force || changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let snapshots = ClipboardShelfSampler.snapshot(from: pasteboard)
        for snapshot in snapshots.reversed() {
            add(snapshot)
        }

        pushUpdates()
    }

    private static func add(_ entry: ClipboardShelfEntry) {
        entries.removeAll { $0.fingerprint == entry.fingerprint }
        entries.insert(entry, at: 0)
        if entries.count > maxStoredEntries {
            entries.removeLast(entries.count - maxStoredEntries)
        }
    }

    private static func clearShelf() {
        entries.removeAll()
        lastChangeCount = NSPasteboard.general.changeCount
        pushUpdates()
    }

    private static func pushUpdates() {
        sendCompact()
        sendExpanded()
    }

    private static func sendCompact() {
        let label = compactLabel()
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "icon": ["type": "sf", "name": compactIconName()],
                    "label": label,
                    "tint": compactTint()
                ]
            ]
        ])
    }

    private static func sendExpanded() {
        var sections: [[String: Any]] = [
            ["type": "text", "content": "剪贴板暂存", "style": "heading"],
            [
                "type": "stat",
                "label": "最近内容",
                "value": "\(entries.count)",
                "icon": ["type": "sf", "name": "clipboard.fill"],
                "tint": compactTint()
            ]
        ]

        if entries.isEmpty {
            sections.append(["type": "text", "content": "暂无剪贴板内容", "style": "caption"])
        } else {
            let items = entries.prefix(maxExpandedEntries).map { entry in
                [
                    "icon": ["type": "sf", "name": entry.type.iconName],
                    "label": entry.preview,
                    "value": entry.valueLabel
                ] as [String: Any]
            }
            sections.append(["type": "divider"])
            sections.append(["type": "list", "items": Array(items)])
        }

        sections.append(["type": "divider"])
        sections.append([
            "type": "button",
            "label": "清空",
            "actionId": "clear",
            "style": "destructive"
        ])

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func compactLabel() -> String {
        let counts = ClipboardShelfType.allCases.compactMap { type -> String? in
            let count = entries.filter { $0.type == type }.count
            guard count > 0 else { return nil }
            return "\(type.compactName) \(min(count, 99))"
        }
        return counts.isEmpty ? "0" : counts.prefix(2).joined(separator: " ")
    }

    private static func compactIconName() -> String {
        entries.first?.type.iconName ?? "doc.on.clipboard"
    }

    private static func compactTint() -> String {
        entries.first?.type.tint ?? "default"
    }

    fileprivate static func clippedPreview(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxPreviewCharacters else {
            return collapsed.isEmpty ? "文本" : collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxPreviewCharacters)
        return "\(collapsed[..<end])..."
    }
}

private struct ClipboardShelfEntry {
    let type: ClipboardShelfType
    let preview: String
    let valueLabel: String
    let fingerprint: String
}

private enum ClipboardShelfType: CaseIterable {
    case text
    case url
    case image

    var compactName: String {
        switch self {
        case .text: return "TXT"
        case .url: return "URL"
        case .image: return "IMG"
        }
    }

    var iconName: String {
        switch self {
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        }
    }

    var tint: String {
        switch self {
        case .text: return "blue"
        case .url: return "green"
        case .image: return "purple"
        }
    }
}

private enum ClipboardShelfSampler {
    private static let imageFingerprintSampleBytes = 4096

    static func snapshot(from pasteboard: NSPasteboard) -> [ClipboardShelfEntry] {
        let items = pasteboard.pasteboardItems ?? []
        if items.isEmpty {
            return singleItemSnapshot(from: pasteboard).map { [$0] } ?? []
        }

        return items.prefix(10).compactMap { item in
            snapshot(from: item)
        }
    }

    private static func singleItemSnapshot(from pasteboard: NSPasteboard) -> ClipboardShelfEntry? {
        if let image = imageEntry(from: pasteboard) {
            return image
        }
        if let value = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) {
            return textOrURLEntry(value)
        }
        return nil
    }

    private static func snapshot(from item: NSPasteboardItem) -> ClipboardShelfEntry? {
        if let image = imageEntry(from: item) {
            return image
        }
        if let value = item.string(forType: .URL) ?? item.string(forType: .fileURL) ?? item.string(forType: .string) {
            return textOrURLEntry(value)
        }
        return nil
    }

    private static func textOrURLEntry(_ rawValue: String) -> ClipboardShelfEntry? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = normalizedURL(from: value) {
            return ClipboardShelfEntry(
                type: .url,
                preview: urlPreview(url),
                valueLabel: "URL",
                fingerprint: "url:\(stableHash(url.absoluteString.lowercased()))"
            )
        }

        return ClipboardShelfEntry(
            type: .text,
            preview: ClipboardShelfPlugin.clippedPreview(value),
            valueLabel: "TXT",
            fingerprint: "text:\(stableHash(value))"
        )
    }

    private static func imageEntry(from pasteboard: NSPasteboard) -> ClipboardShelfEntry? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return imageEntry(from: data)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return imageEntry(image: image, data: nil)
        }
        return nil
    }

    private static func imageEntry(from item: NSPasteboardItem) -> ClipboardShelfEntry? {
        if let data = item.data(forType: .png) ?? item.data(forType: .tiff) {
            return imageEntry(from: data)
        }
        return nil
    }

    private static func imageEntry(from data: Data) -> ClipboardShelfEntry? {
        guard let image = NSImage(data: data) else { return nil }
        return imageEntry(image: image, data: data)
    }

    private static func imageEntry(image: NSImage, data: Data?) -> ClipboardShelfEntry {
        let dimensions = imageDimensions(image)
        let preview: String
        if let dimensions {
            preview = "图片 \(dimensions.width)x\(dimensions.height)"
        } else {
            preview = "图片"
        }

        let dimensionKey = dimensions.map { "\($0.width)x\($0.height)" } ?? "unknown"
        let dataKey = data.map(imageDataFingerprint) ?? stableHash(dimensionKey)
        return ClipboardShelfEntry(
            type: .image,
            preview: preview,
            valueLabel: "IMG",
            fingerprint: "image:\(dimensionKey):\(dataKey)"
        )
    }

    private static func normalizedURL(from value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }

        guard value.contains("."),
              !value.contains(" "),
              let url = URL(string: "https://\(value)") else {
            return nil
        }
        return url
    }

    private static func urlPreview(_ url: URL) -> String {
        if url.isFileURL {
            return url.lastPathComponent.isEmpty ? "file://" : url.lastPathComponent
        }

        if let host = url.host(percentEncoded: false), !host.isEmpty {
            let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if url.path.isEmpty || url.path == "/" {
                return trimmedHost
            }
            return "\(trimmedHost)\(shortPath(url.path))"
        }

        return ClipboardShelfPlugin.clippedPreview(url.absoluteString)
    }

    private static func shortPath(_ path: String) -> String {
        guard path.count > 20 else { return path }
        let end = path.index(path.startIndex, offsetBy: 20)
        return "\(path[..<end])..."
    }

    private static func imageDimensions(_ image: NSImage) -> (width: Int, height: Int)? {
        let reps = image.representations
        if let best = reps.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }),
           best.pixelsWide > 0,
           best.pixelsHigh > 0 {
            return (best.pixelsWide, best.pixelsHigh)
        }

        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func imageDataFingerprint(_ data: Data) -> String {
        var sample = Data()
        sample.append(contentsOf: withUnsafeBytes(of: UInt64(data.count).bigEndian, Array.init))
        sample.append(data.prefix(imageFingerprintSampleBytes))
        if data.count > imageFingerprintSampleBytes {
            sample.append(data.suffix(imageFingerprintSampleBytes))
        }
        return stableHash(sample)
    }

    private static func stableHash(_ value: String) -> String {
        stableHash(Data(value.utf8))
    }

    private static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
