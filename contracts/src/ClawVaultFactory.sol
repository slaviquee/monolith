// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClawVaultWallet} from "./ClawVaultWallet.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

/// @title ClawVaultFactory
/// @notice CREATE2 deterministic deployment factory for ClawVaultWallet.
/// @dev Compatible with ERC-4337 initCode pattern: factory address + calldata.
contract ClawVaultFactory {
    IEntryPoint public immutable entryPoint;

    event WalletCreated(address indexed wallet, uint256 signerX, uint256 signerY, address recoveryAddress);

    error WalletAlreadyDeployed();

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
    }

    /// @notice Deploy a new ClawVaultWallet using CREATE2.
    /// @param signerX P-256 public key x-coordinate.
    /// @param signerY P-256 public key y-coordinate.
    /// @param recoveryAddress Recovery EOA.
    /// @param dailyCap Daily ETH spending cap in wei.
    /// @param dailyStablecoinCap Daily stablecoin spending cap (18-decimal normalized).
    /// @param stablecoins Known stablecoin addresses on this chain.
    /// @param stablecoinDecs Decimals for each stablecoin (parallel array).
    /// @param usePrecompile Whether P-256 precompile is available.
    /// @param salt CREATE2 salt for deterministic addressing.
    /// @return wallet The deployed wallet address.
    function createAccount(
        uint256 signerX,
        uint256 signerY,
        address recoveryAddress,
        uint256 dailyCap,
        uint256 dailyStablecoinCap,
        address[] calldata stablecoins,
        uint8[] calldata stablecoinDecs,
        bool usePrecompile,
        bytes32 salt
    ) external returns (ClawVaultWallet wallet) {
        bytes32 actualSalt = _computeSalt(signerX, signerY, recoveryAddress, salt);

        // Check if already deployed
        address predicted = getAddress(signerX, signerY, recoveryAddress, dailyCap, dailyStablecoinCap, stablecoins, stablecoinDecs, usePrecompile, salt);
        if (predicted.code.length > 0) revert WalletAlreadyDeployed();

        // Deploy fresh wallet via CREATE2 with all init params in constructor
        wallet = new ClawVaultWallet{salt: actualSalt}(
            entryPoint, signerX, signerY, recoveryAddress, dailyCap, dailyStablecoinCap, stablecoins, stablecoinDecs, usePrecompile
        );

        emit WalletCreated(address(wallet), signerX, signerY, recoveryAddress);
    }

    /// @notice Compute the counterfactual address without deploying.
    function getAddress(
        uint256 signerX,
        uint256 signerY,
        address recoveryAddress,
        uint256 dailyCap,
        uint256 dailyStablecoinCap,
        address[] calldata stablecoins,
        uint8[] calldata stablecoinDecs,
        bool usePrecompile,
        bytes32 salt
    ) public view returns (address) {
        bytes32 actualSalt = _computeSalt(signerX, signerY, recoveryAddress, salt);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(ClawVaultWallet).creationCode,
                abi.encode(entryPoint, signerX, signerY, recoveryAddress, dailyCap, dailyStablecoinCap, stablecoins, stablecoinDecs, usePrecompile)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), actualSalt, initCodeHash)
                    )
                )
            )
        );
    }

    function _computeSalt(
        uint256 signerX,
        uint256 signerY,
        address recoveryAddress,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(signerX, signerY, recoveryAddress, salt));
    }
}
