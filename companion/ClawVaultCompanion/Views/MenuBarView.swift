import SwiftUI

/// Menu bar dropdown content — shows daemon status and pending approvals.
struct MenuBarView: View {
    @ObservedObject var xpcClient: CompanionXPCClient

    var body: some View {
        VStack(alignment: .leading) {
            // Status
            HStack {
                Circle()
                    .fill(xpcClient.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(xpcClient.isConnected ? "Connected to daemon" : "Daemon offline")
                    .font(.caption)
            }

            Divider()

            // Pending approvals
            if xpcClient.pendingApprovals.isEmpty {
                Text("No pending approvals")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("Pending Approvals (\(xpcClient.pendingApprovals.count))")
                    .font(.caption.bold())

                ForEach(xpcClient.pendingApprovals) { approval in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(approval.summary)
                            .font(.caption)
                            .lineLimit(2)
                        HStack {
                            Text("Approval code shown in notification")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(approval.timeRemaining)
                                .font(.caption2)
                                .foregroundStyle(approval.isExpired ? .red : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }

            Divider()

            Button("Refresh") {
                xpcClient.refreshPendingApprovals()
            }
            .keyboardShortcut("r")

            Button("Quit ClawVault Companion") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .sheet(item: $xpcClient.activeApprovalRequest) { request in
            AdminApprovalView(request: request)
        }
    }
}
