import Foundation

enum PresetDisplayName {
    static let knownMap: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack",
        "com.barebones.bbedit": "BBEdit",
        "com.apple.Notes": "Notes",
        "com.apple.MobileSMS": "Messages",
    ]

    static func resolve(bundleID: String?) -> String {
        guard let id = bundleID, !id.isEmpty else { return "default" }
        if let mapped = knownMap[id] { return mapped }
        let segment = id.split(separator: ".").last.map(String.init) ?? ""
        guard !segment.isEmpty else { return "default" }
        return segment.prefix(1).uppercased() + segment.dropFirst()
    }
}
