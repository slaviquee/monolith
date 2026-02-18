import Foundation

/// Developer ID Team Identifier for XPC code-signing validation.
/// Replace "REPLACE_ME" with your actual Apple Developer Team ID before release builds.
/// Debug builds skip XPC validation entirely (uses dev-mode flag instead).
enum TeamConfig {
    #if DEBUG
    static let teamID = "UNUSED_IN_DEBUG"
    #else
    static let teamID = "REPLACE_ME"  // ← Set your Team ID here for release
    #endif
}
