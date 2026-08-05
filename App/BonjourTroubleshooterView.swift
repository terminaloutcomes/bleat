import SwiftUI

struct BonjourTroubleshooterView: View {
    @State private var state: NearbyServerDiscoveryState = .idle
    @State private var discovery: BonjourNearbyServerDiscovery?

    var body: some View {
        List {
            switch state {
            case .idle, .searching:
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for Audiobookshelf servers")
                    }
                    .accessibilityIdentifier(
                        "diagnostics.bonjour.searching"
                    )
                }
            case .results(let results):
                ForEach(results) { result in
                    resultSection(result)
                }
                Section {
                    runAgainButton
                }
            case .noResults:
                Section {
                    Text("No Audiobookshelf Bonjour services were found.")
                    runAgainButton
                }
                .accessibilityIdentifier(
                    "diagnostics.bonjour.noResults"
                )
            case .failed(let failure):
                Section {
                    LabeledContent("Result", value: failure.title)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                    runAgainButton
                }
                .accessibilityIdentifier("diagnostics.bonjour.error")
            }
        }
        .navigationTitle("Bonjour Troubleshooter")
        .task {
            start()
        }
        .onDisappear {
            discovery?.cancel()
            discovery = nil
            state = .idle
        }
    }

    private func resultSection(
        _ result: NearbyServerResult
    ) -> some View {
        Section(result.name) {
            LabeledContent("Service", value: result.resolution.service.name)
            LabeledContent("Host", value: result.resolution.host)
            LabeledContent(
                "Port",
                value: String(result.resolution.port)
            )
            LabeledContent("TXT Path", value: result.resolution.path)
            LabeledContent(
                "Resolved URL",
                value: result.resolution.baseURL.url.absoluteString
            )
            LabeledContent(
                "/status",
                value: "Verified Audiobookshelf \(result.server.version)"
            )
            LabeledContent(
                "Final URL",
                value: result.server.baseURL.url.absoluteString
            )
        }
        .accessibilityIdentifier("diagnostics.bonjour.result")
    }

    private var runAgainButton: some View {
        Button("Run Again", action: start)
            .accessibilityIdentifier("diagnostics.bonjour.retry")
    }

    private func start() {
        let discovery = self.discovery ?? BonjourNearbyServerDiscovery()
        self.discovery = discovery
        discovery.start { state in
            self.state = state
        }
    }
}
