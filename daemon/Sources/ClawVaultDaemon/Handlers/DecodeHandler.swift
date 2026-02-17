import Foundation

/// POST /decode — Decode intent into human-readable summary (no signing).
struct DecodeHandler {
    let configStore: ConfigStore
    let stablecoinRegistry: StablecoinRegistry
    let protocolRegistry: ProtocolRegistry

    func handle(request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let target = json["target"] as? String,
            let calldataHex = json["calldata"] as? String,
            let valueStr = json["value"] as? String
        else {
            return .error(400, "Missing required fields: target, calldata, value")
        }

        let config = configStore.read()
        let calldata = SignatureUtils.fromHex(calldataHex) ?? Data()
        let value = UInt64(valueStr) ?? 0
        let chainId = config.homeChainId

        let decoded = CalldataDecoder.decode(
            calldata: calldata,
            target: target,
            value: value,
            chainId: chainId,
            stablecoinRegistry: stablecoinRegistry,
            protocolRegistry: protocolRegistry
        )

        return .json(200, [
            "action": decoded.action,
            "summary": decoded.summary,
            "selector": decoded.selector,
            "isKnown": decoded.isKnown,
            "chainId": chainId,
        ])
    }
}
