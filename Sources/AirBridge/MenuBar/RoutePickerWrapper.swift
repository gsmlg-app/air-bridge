import SwiftUI
import AVKit

struct RoutePickerWrapper: NSViewRepresentable {
    let player: AVPlayer?
    let onWillBeginPresentingRoutes: () -> Void

    init(player: AVPlayer? = nil, onWillBeginPresentingRoutes: @escaping () -> Void = {}) {
        self.player = player
        self.onWillBeginPresentingRoutes = onWillBeginPresentingRoutes
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWillBeginPresentingRoutes: onWillBeginPresentingRoutes)
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.player = player
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
        nsView.delegate = context.coordinator
        context.coordinator.onWillBeginPresentingRoutes = onWillBeginPresentingRoutes
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onWillBeginPresentingRoutes: () -> Void

        init(onWillBeginPresentingRoutes: @escaping () -> Void) {
            self.onWillBeginPresentingRoutes = onWillBeginPresentingRoutes
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            DispatchQueue.main.async { [onWillBeginPresentingRoutes] in
                onWillBeginPresentingRoutes()
            }
        }
    }
}
