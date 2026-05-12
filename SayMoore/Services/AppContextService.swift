import Foundation
#if canImport(AppKit)
import AppKit
#endif

protocol WorkspaceProvider: Sendable {
    var frontmostBundleID: String? { get }
}

#if canImport(AppKit)
struct NSWorkspaceProvider: WorkspaceProvider {
    var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
#endif

final class BundleIDCapturer {
    private let provider: WorkspaceProvider
    private let ownBundleID: String
    private var lastNonSelf: String?

    init(provider: WorkspaceProvider, ownBundleID: String) {
        self.provider = provider
        self.ownBundleID = ownBundleID
    }

    @discardableResult
    func capture() -> String? {
        let current = provider.frontmostBundleID
        if let id = current, id != ownBundleID {
            lastNonSelf = id
            return id
        }
        return lastNonSelf
    }
}
