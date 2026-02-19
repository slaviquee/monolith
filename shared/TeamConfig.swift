import Foundation

/// Developer ID Team Identifier for XPC code-signing validation.
/// Debug builds skip XPC validation entirely (uses dev-mode flag instead).
enum TeamConfig {
    #if DEBUG
    static let teamID = "UNUSED_IN_DEBUG"
    #else
    static let teamID = "Q4E837WNXN"
    #endif
}
