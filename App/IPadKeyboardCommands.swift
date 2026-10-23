#if os(iOS)
    import Combine
    import Observation
    import SwiftUI
    import UIKit

    enum IPadKeyboardAction: CaseIterable, Equatable, Sendable {
        case togglePlayback, skipBackward, skipForward, slower, faster, search
    }

    struct IPadKeyboardAvailability {
        let isPad: Bool
        let isSignedIn: Bool
        let isSceneActive: Bool
        let isEditingText: Bool
        let isPresentationAllowed: Bool
        let isPlaybackAvailable: Bool
        let isToggleAvailable: Bool

        func allows(_ action: IPadKeyboardAction) -> Bool {
            guard isPad, isSignedIn, isSceneActive, isPresentationAllowed else {
                return false
            }
            if action == .search { return true }
            if action == .togglePlayback {
                return !isEditingText && isToggleAvailable
            }
            return !isEditingText && isPlaybackAvailable
        }
    }

    @MainActor
    @Observable
    final class IPadKeyboardScene {
        @ObservationIgnored weak var window: UIWindow?
        @ObservationIgnored weak var playerAnchor: UIView?
        private(set) var focusRevision: UInt64 = 0

        func refresh() { focusRevision &+= 1 }

        func availability(model: AppModel) -> IPadKeyboardAvailability {
            _ = focusRevision
            let active =
                window?.isKeyWindow == true
                && window?.windowScene?.activationState == .foregroundActive
            let first = window.flatMap { Self.firstResponder(in: $0) }
            var top = window?.rootViewController
            var transitioning = top?.isBeingDismissed == true
            while let presented = top?.presentedViewController {
                transitioning =
                    transitioning || presented.isBeingDismissed
                    || presented.isBeingPresented
                top = presented
            }
            let root = window?.rootViewController
            let allowed =
                !transitioning
                && (top === root
                    || (playerAnchor?.window === window
                        && top?.viewIfLoaded.map {
                            playerAnchor?.isDescendant(of: $0) == true
                        } == true))
            return IPadKeyboardAvailability(
                isPad: UIDevice.current.userInterfaceIdiom == .pad,
                isSignedIn: model.phase == .signedIn,
                isSceneActive: active,
                isEditingText: first is any UITextInput,
                isPresentationAllowed: allowed,
                isPlaybackAvailable: model.playback.isPlaybackControlAvailable,
                isToggleAvailable: model.playback.isPlaybackToggleAvailable)
        }

        private static func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let responder = firstResponder(in: child) {
                    return responder
                }
            }
            return nil
        }
    }

    @MainActor
    struct IPadKeyboardContext {
        let model: AppModel
        let navigation: AppNavigationCoordinator
        let scene: IPadKeyboardScene

        func allows(_ action: IPadKeyboardAction) -> Bool {
            scene.availability(model: model).allows(action)
        }

        func perform(_ action: IPadKeyboardAction) {
            // Validate the actual responder/presentation again at delivery;
            // editing notifications only refresh command discoverability.
            guard allows(action) else { return }
            switch action {
            case .togglePlayback:
                _ = model.playback.handleRemoteCommand(.toggle)
            case .skipBackward:
                _ = model.playback.handleRemoteCommand(.skipBackward)
            case .skipForward:
                _ = model.playback.handleRemoteCommand(.skipForward)
            case .slower:
                _ = model.playback.stepFeaturedPlaybackRate(.decrease)
            case .faster:
                _ = model.playback.stepFeaturedPlaybackRate(.increase)
            case .search:
                navigation.requestKeyboardSearch()
            }
        }
    }

    private struct IPadKeyboardSceneKey: EnvironmentKey {
        static let defaultValue: IPadKeyboardScene? = nil
    }

    extension EnvironmentValues {
        var ipadKeyboardScene: IPadKeyboardScene? {
            get { self[IPadKeyboardSceneKey.self] }
            set { self[IPadKeyboardSceneKey.self] = newValue }
        }
    }

    private struct IPadKeyboardButtons: View {
        let context: IPadKeyboardContext

        var body: some View {
            VStack {
                command("Play/Pause", action: .togglePlayback)
                    .keyboardShortcut("p", modifiers: .command)
                command("Skip Backward", action: .skipBackward)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                command("Skip Forward", action: .skipForward)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                command("Slower", action: .slower)
                    .keyboardShortcut("-", modifiers: .command)
                command("Faster", action: .faster)
                    .keyboardShortcut("+", modifiers: .command)
                command("Search", action: .search)
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        private func command(
            _ title: LocalizedStringKey, action: IPadKeyboardAction
        ) -> some View {
            Button(title) { context.perform(action) }
                .disabled(!context.allows(action))
        }
    }

    struct IPadKeyboardScope: ViewModifier {
        let model: AppModel
        let navigation: AppNavigationCoordinator
        @State private var scene = IPadKeyboardScene()
        @Environment(\.scenePhase) private var scenePhase

        func body(content: Content) -> some View {
            let context = IPadKeyboardContext(
                model: model, navigation: navigation, scene: scene)
            return
                content
                .background(alignment: .topLeading) {
                    IPadKeyboardAnchor(scene: scene, isPlayer: false)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .environment(\.ipadKeyboardScene, scene)
                .overlay(alignment: .topLeading) {
                    // Register native shortcuts in this scene without adding
                    // invisible focus targets or changing the content layout.
                    IPadKeyboardButtons(context: context)
                        .frame(width: 0, height: 0)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onChange(of: scenePhase) { _, _ in scene.refresh() }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIWindow.didBecomeKeyNotification
                    )
                    .merge(
                        with: NotificationCenter.default.publisher(
                            for: UIWindow.didResignKeyNotification)
                    )
                    .receive(on: RunLoop.main)
                ) { notification in
                    guard let window = notification.object as? UIWindow,
                        window === scene.window
                    else { return }
                    scene.refresh()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UITextField.textDidBeginEditingNotification
                    )
                    .merge(
                        with: NotificationCenter.default.publisher(
                            for: UITextField.textDidEndEditingNotification)
                    )
                    .merge(
                        with: NotificationCenter.default.publisher(
                            for: UITextView.textDidBeginEditingNotification)
                    )
                    .merge(
                        with: NotificationCenter.default.publisher(
                            for: UITextView.textDidEndEditingNotification)
                    )
                    .receive(on: RunLoop.main)
                ) { _ in scene.refresh() }
        }
    }

    struct IPadPlayerKeyboardScope: ViewModifier {
        @Environment(\.ipadKeyboardScene) private var scene

        func body(content: Content) -> some View {
            content.background {
                if let scene {
                    IPadKeyboardAnchor(scene: scene, isPlayer: true)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private struct IPadKeyboardAnchor: UIViewControllerRepresentable {
        let scene: IPadKeyboardScene
        let isPlayer: Bool

        func makeUIViewController(context: Context) -> Anchor {
            let controller = Anchor()
            controller.scene = scene
            controller.isPlayer = isPlayer
            return controller
        }

        func updateUIViewController(_ controller: Anchor, context: Context) {}

        static func dismantleUIViewController(
            _ controller: Anchor, coordinator: ()
        ) {
            if controller.scene?.playerAnchor === controller.viewIfLoaded {
                controller.scene?.playerAnchor = nil
            }
            controller.scene?.refresh()
        }

        final class Anchor: UIViewController {
            weak var scene: IPadKeyboardScene?
            var isPlayer = false

            override func loadView() {
                let anchor = UIView()
                anchor.isUserInteractionEnabled = false
                anchor.isAccessibilityElement = false
                view = anchor
            }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                guard let scene else { return }
                if isPlayer {
                    scene.playerAnchor = view
                } else {
                    scene.window = view.window
                }
                scene.refresh()
            }
        }
    }
#endif
