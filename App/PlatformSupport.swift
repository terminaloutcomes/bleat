import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
    typealias PlatformImage = UIImage
#else
    import AppKit
    typealias PlatformImage = NSImage
#endif

enum PlatformImageSupport {
    static func image(from data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }
    static func size(of image: PlatformImage) -> CGSize { image.size }
    static func pixelSize(of image: PlatformImage) -> CGSize {
        #if os(iOS)
            CGSize(
                width: image.size.width * image.scale,
                height: image.size.height * image.scale
            )
        #else
            image.size
        #endif
    }

    @ViewBuilder
    static func view(for image: PlatformImage) -> some View {
        #if os(iOS)
            Image(uiImage: image)
        #else
            Image(nsImage: image)
        #endif
    }

    @ViewBuilder
    static func resizableView(for image: PlatformImage) -> some View {
        #if os(iOS)
            Image(uiImage: image).resizable()
        #else
            Image(nsImage: image).resizable()
        #endif
    }
}

extension View {
    @ViewBuilder
    func iOSInlineNavigationTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }

    @ViewBuilder
    func iOSServerURLInput() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
        #else
            self
        #endif
    }

    @ViewBuilder
    func iOSNoAutocapitalization() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            self
        #endif
    }
}

enum PlatformClipboard {
    static func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum PlatformDevice {
    static var operatingSystem: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
    @MainActor
    static var model: String {
        #if os(iOS)
            UIDevice.current.model
        #else
            "Mac"
        #endif
    }
}

@MainActor
final class InstallationIdentifierStore {
    private static let key = "bleat.installationIdentifier.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var identifier: String { uuid.uuidString.lowercased() }

    var uuid: UUID {
        if let value = defaults.string(forKey: Self.key),
            let identifier = UUID(uuidString: value)
        {
            return identifier
        }
        let identifier = UUID()
        defaults.set(identifier.uuidString.lowercased(), forKey: Self.key)
        return identifier
    }
}
