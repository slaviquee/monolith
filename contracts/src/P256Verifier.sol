// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title P256SignatureVerifier
/// @notice Verifies P-256 signatures using precompile at 0x100 with fallback to Daimo verifier.
/// @dev Enforces low-S normalization: rejects signatures where s > n/2.
library P256SignatureVerifier {
    /// @dev P-256 curve order
    uint256 internal constant P256_N =
        0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    /// @dev P-256 curve order / 2 for low-S check
    uint256 internal constant P256_N_DIV_2 =
        57896044605178124381348723474703786764998477612067880171211129530534256022184;

    /// @dev EIP-7951 / RIP-7212 precompile address
    address internal constant PRECOMPILE = address(0x100);

    /// @dev Daimo P256Verifier fallback contract
    address internal constant DAIMO_VERIFIER = 0xc2b78104907F722DABAc4C69f826a522B2754De4;

    error SignatureHighS();

    /// @notice Verify a P-256 signature with low-S enforcement.
    /// @param messageHash The hash of the signed message.
    /// @param r The r component of the signature.
    /// @param s The s component of the signature (must be low-S normalized).
    /// @param x The x coordinate of the public key.
    /// @param y The y coordinate of the public key.
    /// @param usePrecompile Whether the precompile is available on this chain.
    /// @return True if the signature is valid.
    function verify(
        bytes32 messageHash,
        uint256 r,
        uint256 s,
        uint256 x,
        uint256 y,
        bool usePrecompile
    ) internal view returns (bool) {
        // Enforce low-S: reject if s > n/2 (defense in depth — daemon normalizes, contract validates)
        if (s > P256_N_DIV_2) {
            revert SignatureHighS();
        }

        bytes memory args = abi.encode(messageHash, r, s, x, y);
        address target = usePrecompile ? PRECOMPILE : DAIMO_VERIFIER;

        (bool success, bytes memory ret) = target.staticcall(args);
        if (!success || ret.length < 32) return false;

        return abi.decode(ret, (uint256)) == 1;
    }
}
