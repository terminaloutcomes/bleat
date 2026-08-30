import Foundation
import SwiftUI

struct AppMetadata: Equatable {
    let appName: String
    let version: String
    let gitCommit: String
    let compileDate: Date?
    let developerName: String
    let bundleIdentifier: String

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        appName = Self.value(
            for: "CFBundleDisplayName",
            in: infoDictionary,
            fallback: "Bleat"
        )
        version = Self.value(
            for: "CFBundleShortVersionString",
            in: infoDictionary,
            fallback: "Unavailable"
        )
        gitCommit = Self.value(
            for: "BleatGitCommit",
            in: infoDictionary,
            fallback: "Unavailable"
        )
        compileDate = Self.compileDate(
            from: infoDictionary["BleatBuildDate"] as? String
        )
        developerName = Self.value(
            for: "BleatDeveloperName",
            in: infoDictionary,
            fallback: "Unavailable"
        )
        self.bundleIdentifier = bundleIdentifier ?? "Unavailable"
    }

    var formattedCompileDate: String {
        guard let compileDate else {
            return "Unavailable"
        }

        return compileDate.formatted(
            date: .abbreviated,
            time: .standard
        )
    }

    private static func value(
        for key: String,
        in infoDictionary: [String: Any],
        fallback: String
    ) -> String {
        guard let value = infoDictionary[key] as? String,
            !value.isEmpty
        else {
            return fallback
        }

        return value
    }

    private static func compileDate(from value: String?) -> Date? {
        guard let value else {
            return nil
        }

        return ISO8601DateFormatter().date(from: value)
    }
}

struct AboutView: View {
    private let metadata: AppMetadata

    init(metadata: AppMetadata = AppMetadata()) {
        self.metadata = metadata
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("LaunchLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 27))
                        .accessibilityHidden(true)

                    Text(metadata.appName)
                        .font(.title.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section("App") {
                LabeledContent("Version", value: metadata.version)
                LabeledContent("Compiled", value: metadata.formattedCompileDate)
                    .monospacedDigit()
                LabeledContent("Developer", value: metadata.developerName)
                LabeledContent("Bundle ID", value: metadata.bundleIdentifier)
            }
        }
        .accessibilityIdentifier("settings.about.details")
    }
}
