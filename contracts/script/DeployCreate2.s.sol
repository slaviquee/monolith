// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MonolithFactory} from "../src/MonolithFactory.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

/// @notice Deploy MonolithFactory deterministically via CREATE2.
/// Uses the Keyless CREATE2 Deployer (Nick's factory) so the factory
/// address is identical on every EVM chain for the same salt.
///
/// Usage:
///   Predict address:  forge script script/DeployCreate2.s.sol:DeployCreate2 --sig "predict()"
///   Deploy on-chain:  forge script script/DeployCreate2.s.sol:DeployCreate2 --rpc-url $RPC_URL --broadcast --verify
contract DeployCreate2 is Script {
    // ERC-4337 v0.7 EntryPoint (same address on all chains)
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // Nick's Keyless CREATE2 Deployer — deployed on every major EVM chain
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Deterministic salt — same value used on every chain for the shared factory
    bytes32 constant SALT = bytes32(uint256(0x4d6f6e6f6c697468)); // "Monolith" in hex

    /// @notice Compute the deterministic factory address without deploying.
    function predict() public pure {
        (address predicted, ) = _computeAddress();
        console.log("Predicted MonolithFactory address:", predicted);
    }

    /// @notice Deploy MonolithFactory via Nick's CREATE2 deployer.
    function run() external {
        (address predicted, bytes memory initCode) = _computeAddress();
        console.log("Predicted factory address:", predicted);

        // Check if already deployed
        if (predicted.code.length > 0) {
            console.log("Factory already deployed at this address, skipping.");
            return;
        }

        vm.startBroadcast();

        // Nick's factory expects: salt (32 bytes) ++ initCode
        (bool success, ) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, initCode));
        require(success, "CREATE2 deployment failed");

        vm.stopBroadcast();

        // Verify deployment
        require(predicted.code.length > 0, "Deployment verification failed");
        console.log("Factory deployed at:", predicted);
    }

    function _computeAddress() internal pure returns (address predicted, bytes memory initCode) {
        initCode = abi.encodePacked(
            type(MonolithFactory).creationCode,
            abi.encode(IEntryPoint(ENTRY_POINT))
        );

        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(initCode))
                    )
                )
            )
        );
    }
}
