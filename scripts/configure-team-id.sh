#!/usr/bin/env bash
# Writes your Apple Developer Team ID into shared/TeamConfig.swift,
# replacing the #error directive so release builds compile.
# Usage: scripts/configure-team-id.sh YOUR_TEAM_ID
# Idempotent — safe to re-run with a new Team ID.

set -euo pipefail

TEAM_ID="${1:-}"
if [[ -z "$TEAM_ID" ]]; then
    echo "Usage: $0 YOUR_TEAM_ID" >&2
    exit 1
fi

# Validate: Apple Team IDs are 10 alphanumeric characters
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Warning: '$TEAM_ID' doesn't look like a standard Apple Team ID (10 alphanumeric chars)." >&2
    echo "Proceeding anyway." >&2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/shared/TeamConfig.swift"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found" >&2
    exit 1
fi

# Replace either the #error line or an existing teamID assignment in the release branch
# We rewrite the entire file to keep it clean
cat > "$CONFIG_FILE" << EOF
import Foundation

/// Developer ID Team Identifier for XPC code-signing validation.
/// Debug builds skip XPC validation entirely (uses dev-mode flag instead).
enum TeamConfig {
    #if DEBUG
    static let teamID = "UNUSED_IN_DEBUG"
    #else
    static let teamID = "$TEAM_ID"
    #endif
}
EOF

echo "Team ID set to '$TEAM_ID' in shared/TeamConfig.swift"
