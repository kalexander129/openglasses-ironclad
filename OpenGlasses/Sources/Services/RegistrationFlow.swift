import Foundation

/// Pure policy for the Meta registration wait ΓÇö the setup step that most often blocks users
/// (the DAT permission gate is *the* onboarding blocker).
///
/// `Wearables.startRegistration()` returns *before* the user has approved the app inside the Meta
/// AI companion app; `registrationState` only reaches the camera/mic-capable value once they do,
/// and that approval has been observed to take ~25 s. The old 10 s deadline gave up while the user
/// was still tapping through Meta AI, leaving a "connected but nothing works" state ΓÇö and the
/// status shown was a raw internal state number, not something the user could act on.
enum RegistrationFlow {
    /// How long to keep polling for the Meta AI approval before giving up (still with guidance).
    static let approvalDeadlineSeconds: Int64 = 25
    /// `registrationState` raw value at which camera/mic capabilities become available.
    static let registeredStateRawValue = 3

    static func isRegistered(stateRaw: Int) -> Bool { stateRaw >= registeredStateRawValue }

    /// User-facing connection status ΓÇö tells the user what to *do*, never an internal state number.
    static func status(stateRaw: Int) -> String {
        isRegistered(stateRaw: stateRaw)
            ? "Waiting for deviceΓÇª"
            : "Approve OpenGlasses in the Meta AI app to continueΓÇª"
    }
}

