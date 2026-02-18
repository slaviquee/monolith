import Foundation

/// Developer ID Team Identifier for XPC code-signing validation.
/// Debug builds skip XPC validation entirely (uses dev-mode flag instead).
enum TeamConfig {
    #if DEBUG
    static let teamID = "UNUSED_IN_DEBUG"
    #else
    // To configure: run `scripts/configure-team-id.sh YOUR_TEAM_ID`
    // or replace the #error below with: static let teamID = "YOUR_TEAM_ID"
    #error("CLAWVAULT_TEAM_ID not configured — run scripts/configure-team-id.sh YOUR_TEAM_ID")
    #endif
}
