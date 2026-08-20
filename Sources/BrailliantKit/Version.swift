import Foundation

/// The version of BrailliantConnect, as one constant.
///
/// It is not read from the bundle: `brailliant` runs perfectly well from
/// `.build/release/`, where there is no bundle to read, and a version that
/// disappears depending on how the program was started is worse than none.
///
/// `VersionTests` compares this against `MARKETING_VERSION` in the Xcode
/// project and fails when they drift, so the two cannot quietly disagree —
/// which is the only way a constant like this stays true.
public enum Version {
    public static let current = "1.0.0"
}
