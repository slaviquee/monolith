import Foundation

/// GET /address — Return wallet address and public key.
struct AddressHandler {
    let configStore: ConfigStore
    let seManager: SecureEnclaveManager

    func handle(request: HTTPRequest) async -> HTTPResponse {
        let config = configStore.read()

        var signerPublicKey: [String: String]
        do {
            let pubKey = try await seManager.signingPublicKey()
            signerPublicKey = [
                "x": SignatureUtils.toHex(pubKey.x),
                "y": SignatureUtils.toHex(pubKey.y),
            ]
        } catch {
            signerPublicKey = ["x": "unavailable", "y": "unavailable"]
        }

        return .json(200, [
            "walletAddress": config.walletAddress ?? "not deployed",
            "signerPublicKey": signerPublicKey,
            "homeChainId": config.homeChainId,
        ] as [String: Any])
    }
}
