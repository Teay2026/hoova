import AppKit
import ApplicationServices

/// Les deux autorisations dont Hoova a besoin. C'est l'utilisateur qui les accorde, dans Réglages Système.
enum Permissions {
    /// Accessibilité : lire le texte des apps et détecter le double ⌃.
    static func askForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Enregistrement de l'écran : l'OCR, pour lire partout (images, PDF scannés…).
    static func askForScreenRecording() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
