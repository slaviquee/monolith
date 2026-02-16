import Foundation

/// GET /address — Return wallet address and public key.
struct AddressHandler {
    let config: DaemonConfig
    let seManager: SecureEnclaveManager

    func handle(request: HTTPRequest) async -> HTTPResponse {
        do {
            let pubKey = try await seManager.signingPublicKey()
            let x = SignatureUtils.toHex(pubKey.x)
            let y = SignatureUtils.toHex(pubKey.y)

            return .json(200, [
                "walletAddress": config.walletAddress ?? "not deployed",
                "signerPublicKey": [
                    "x": x,
                    "y": y,
                ],
                "homeChainId": config.homeChainId,
            ] as [String: Any])
        } catch {
            return .error(500, "Failed to read public key: \(error.localizedDescription)")
        }
    }
}
