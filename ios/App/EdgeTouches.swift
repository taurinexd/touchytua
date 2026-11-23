import UIKit

/// Near the edges of the screen iOS holds a touch back until it knows the
/// finger is not starting a system gesture: about two thirds of a second
/// for a finger that rests. The controls at the bottom of a session are
/// in that strip, and a hold on them felt a second late. The system's
/// own recognizers keep working; they only stop delaying the touch on its
/// way to the app.
enum EdgeTouches {
    @MainActor static func deliverAtOnce() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                for recognizer in window.gestureRecognizers ?? [] where recognizer.delaysTouchesBegan {
                    recognizer.delaysTouchesBegan = false
                }
            }
        }
    }
}
