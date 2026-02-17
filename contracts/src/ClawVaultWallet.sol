// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {P256SignatureVerifier} from "./P256Verifier.sol";

/// @title ClawVaultWallet
/// @notice ERC-4337 smart wallet with P-256 signature verification, on-chain spending caps, and recovery.
/// @dev Fork of Coinbase Smart Wallet — simplified to single P-256 owner.
///      Signature format: raw r||s (64 bytes). Low-S enforced on-chain.
///      Precompile at 0x100 when available, fallback to Daimo P256Verifier.
contract ClawVaultWallet is IAccount {
    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    uint48 public constant RECOVERY_DELAY = 48 hours;
    uint48 public constant UNFREEZE_DELAY = 10 minutes;

    // ─── Immutables ───────────────────────────────────────────────────────────
    IEntryPoint public immutable entryPoint;

    // ─── Signer State ─────────────────────────────────────────────────────────
    uint256 public signerX;
    uint256 public signerY;

    // ─── Precompile ───────────────────────────────────────────────────────────
    bool public usePrecompile;

    // ─── Spending Policy ──────────────────────────────────────────────────────
    uint256 public dailySpendingCap;
    uint256 public spentToday;
    uint256 public currentDay;
    mapping(address => bool) public knownStablecoins;

    // ─── Stablecoin Spending (separate counter with decimal normalization) ───
    uint256 public dailyStablecoinCap;
    uint256 public stablecoinSpentToday;
    mapping(address => uint8) public stablecoinDecimals;

    // ─── Recovery State ───────────────────────────────────────────────────────
    address public recoveryAddress;
    bool public frozen;
    uint256 public pendingSignerX;
    uint256 public pendingSignerY;
    uint64 public recoveryReadyAt;
    uint64 public unfreezeReadyAt;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Executed(address indexed target, uint256 value, bytes data);
    event SpendingTracked(uint256 amount, uint256 spentToday, uint256 dailyCap);
    event Frozen(address indexed caller);
    event UnfreezeRequested(uint64 readyAt);
    event Unfrozen(address indexed caller);
    event KeyRotationInitiated(bytes newPubKey, uint64 readyAt);
    event KeyRotationFinalized(bytes newPubKey);
    event DailyCapUpdated(uint256 newCap);
    event DailyStablecoinCapUpdated(uint256 newCap);
    event StablecoinUpdated(address token, bool status, uint8 decimals);
    event StablecoinSpendingTracked(uint256 normalizedAmount, uint256 stablecoinSpentToday, uint256 dailyStablecoinCap);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error OnlyEntryPoint();
    error OnlySelf();
    error OnlyRecovery();
    error OnlyRecoveryOrSigner();
    error WalletFrozen();
    error DailyCapExceeded(uint256 attempted, uint256 remaining);
    error RecoveryNotReady();
    error UnfreezeNotReady();
    error NoPendingRotation();
    error NoUnfreezeRequested();
    error InvalidSignatureLength();
    error NoPaymastersAllowed();
    error InvalidPublicKey();
    error InvalidRecoveryAddress();
    error DailyStablecoinCapExceeded(uint256 attempted, uint256 remaining);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier onlyRecovery() {
        if (msg.sender != recoveryAddress) revert OnlyRecovery();
        _;
    }

    modifier whenNotFrozen() {
        if (frozen) revert WalletFrozen();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @param _entryPoint The ERC-4337 EntryPoint contract address.
    /// @param _signerX P-256 public key x-coordinate.
    /// @param _signerY P-256 public key y-coordinate.
    /// @param _recoveryAddress EOA or hardware wallet for emergency recovery.
    /// @param _dailyCap Daily spending cap in wei for native ETH.
    /// @param _dailyStablecoinCap Daily spending cap for stablecoins (18-decimal normalized).
    /// @param _stablecoins Array of known stablecoin addresses on this chain.
    /// @param _stablecoinDecs Decimals for each stablecoin (parallel array with _stablecoins).
    /// @param _usePrecompile Whether the P-256 precompile is available.
    constructor(
        IEntryPoint _entryPoint,
        uint256 _signerX,
        uint256 _signerY,
        address _recoveryAddress,
        uint256 _dailyCap,
        uint256 _dailyStablecoinCap,
        address[] memory _stablecoins,
        uint8[] memory _stablecoinDecs,
        bool _usePrecompile
    ) {
        if (_recoveryAddress == address(0)) revert InvalidRecoveryAddress();
        if (_signerX == 0 || _signerY == 0) revert InvalidPublicKey();
        require(_stablecoins.length == _stablecoinDecs.length, "Stablecoin/decimals length mismatch");
        entryPoint = _entryPoint;
        signerX = _signerX;
        signerY = _signerY;
        recoveryAddress = _recoveryAddress;
        dailySpendingCap = _dailyCap;
        dailyStablecoinCap = _dailyStablecoinCap;
        usePrecompile = _usePrecompile;
        currentDay = block.timestamp / 1 days;

        for (uint256 i = 0; i < _stablecoins.length; i++) {
            knownStablecoins[_stablecoins[i]] = true;
            stablecoinDecimals[_stablecoins[i]] = _stablecoinDecs[i];
        }
    }

    // ─── ERC-4337 Validation ──────────────────────────────────────────────────
    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // §6.5: paymasterAndData MUST be empty — no paymasters allowed
        if (userOp.paymasterAndData.length > 0) revert NoPaymastersAllowed();

        validationData = _validateSignature(userOp.signature, userOpHash);

        if (missingAccountFunds > 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds}("");
            success; // EntryPoint will verify
        }
    }

    // ─── Execution ────────────────────────────────────────────────────────────
    /// @notice Execute a single call from this wallet.
    /// @dev Only callable by the EntryPoint (via validated UserOp).
    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPoint whenNotFrozen {
        _trackSpending(target, value, data);
        _call(target, value, data);
        emit Executed(target, value, data);
    }

    /// @notice Execute a batch of calls from this wallet.
    /// @dev Only callable by the EntryPoint (via validated UserOp).
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyEntryPoint whenNotFrozen {
        require(targets.length == values.length && values.length == datas.length, "Length mismatch");
        for (uint256 i = 0; i < targets.length; i++) {
            _trackSpending(targets[i], values[i], datas[i]);
            _call(targets[i], values[i], datas[i]);
            emit Executed(targets[i], values[i], datas[i]);
        }
    }

    // ─── ERC-1271: isValidSignature ───────────────────────────────────────────
    /// @notice Verify a signature for off-chain use (ERC-1271).
    /// @param hash The hash that was signed.
    /// @param signature Raw r||s P-256 signature (64 bytes).
    /// @return magicValue 0x1626ba7e if valid, 0xffffffff otherwise.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 64) return bytes4(0xffffffff);

        (uint256 r, uint256 s) = abi.decode(signature, (uint256, uint256));
        bool valid = P256SignatureVerifier.verify(hash, r, s, signerX, signerY, usePrecompile);

        return valid ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    // ─── Recovery Functions ───────────────────────────────────────────────────
    /// @notice Freeze the wallet immediately. Callable by recovery address or current signer (via UserOp → self-call).
    function freeze() external {
        if (msg.sender != recoveryAddress && msg.sender != address(this)) {
            revert OnlyRecoveryOrSigner();
        }
        frozen = true;
        emit Frozen(msg.sender);
    }

    /// @notice Request an unfreeze with a time delay. Callable only by recovery address.
    function requestUnfreeze() external onlyRecovery {
        unfreezeReadyAt = uint64(block.timestamp + UNFREEZE_DELAY);
        emit UnfreezeRequested(unfreezeReadyAt);
    }

    /// @notice Finalize the unfreeze after the delay has passed. Callable only by recovery address.
    function finalizeUnfreeze() external onlyRecovery {
        if (unfreezeReadyAt == 0) revert NoUnfreezeRequested();
        if (block.timestamp < unfreezeReadyAt) revert UnfreezeNotReady();
        frozen = false;
        unfreezeReadyAt = 0;
        emit Unfrozen(msg.sender);
    }

    /// @notice Initiate key rotation with a 48h timelock. Auto-freezes. Callable only by recovery address.
    function initiateKeyRotation(uint256 newX, uint256 newY) external onlyRecovery {
        if (newX == 0 || newY == 0) revert InvalidPublicKey();
        pendingSignerX = newX;
        pendingSignerY = newY;
        recoveryReadyAt = uint64(block.timestamp + RECOVERY_DELAY);
        frozen = true;
        emit Frozen(msg.sender);
        emit KeyRotationInitiated(abi.encodePacked(newX, newY), recoveryReadyAt);
    }

    /// @notice Finalize key rotation after 48h delay. Callable only by recovery address.
    function finalizeKeyRotation() external onlyRecovery {
        if (pendingSignerX == 0 && pendingSignerY == 0) revert NoPendingRotation();
        if (block.timestamp < recoveryReadyAt) revert RecoveryNotReady();

        signerX = pendingSignerX;
        signerY = pendingSignerY;
        emit KeyRotationFinalized(abi.encodePacked(pendingSignerX, pendingSignerY));

        pendingSignerX = 0;
        pendingSignerY = 0;
        recoveryReadyAt = 0;
        // Does NOT auto-unfreeze — unfreezing is a separate, explicit action
    }

    // ─── Spending Cap Admin (recovery-only — independent of signing key) ──────
    /// @notice Update the daily spending cap. Only callable by recovery address.
    /// @dev Uses onlyRecovery (not onlySelf) so the signing key cannot raise caps
    ///      to infinity — the on-chain cap is a true backstop independent of the daemon.
    function setDailyCap(uint256 newCap) external onlyRecovery {
        dailySpendingCap = newCap;
        emit DailyCapUpdated(newCap);
    }

    /// @notice Update the daily stablecoin spending cap. Only callable by recovery address.
    function setDailyStablecoinCap(uint256 newCap) external onlyRecovery {
        dailyStablecoinCap = newCap;
        emit DailyStablecoinCapUpdated(newCap);
    }

    /// @notice Update stablecoin registry with decimals. Only callable by recovery address.
    /// @dev Uses onlyRecovery (not onlySelf) so the signing key cannot manipulate
    ///      which tokens are tracked for spending caps.
    function setStablecoin(address token, bool status, uint8 decimals) external onlyRecovery {
        knownStablecoins[token] = status;
        stablecoinDecimals[token] = decimals;
        emit StablecoinUpdated(token, status, decimals);
    }

    // ─── Receive ETH ──────────────────────────────────────────────────────────
    receive() external payable {}

    // ─── Internal Functions ───────────────────────────────────────────────────
    function _validateSignature(bytes calldata signature, bytes32 userOpHash) internal view returns (uint256) {
        if (signature.length != 64) revert InvalidSignatureLength();

        (uint256 r, uint256 s) = abi.decode(signature, (uint256, uint256));
        bool valid = P256SignatureVerifier.verify(userOpHash, r, s, signerX, signerY, usePrecompile);

        return valid ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
    }

    function _trackSpending(address target, uint256 value, bytes calldata data) internal {
        uint256 day = block.timestamp / 1 days;
        if (day != currentDay) {
            spentToday = 0;
            stablecoinSpentToday = 0;
            currentDay = day;
        }

        // Track native ETH value against ETH cap
        if (value > 0) {
            uint256 ethRemaining = dailySpendingCap > spentToday ? dailySpendingCap - spentToday : 0;
            if (value > ethRemaining) {
                revert DailyCapExceeded(value, ethRemaining);
            }
            spentToday += value;
            emit SpendingTracked(value, spentToday, dailySpendingCap);
        }

        // Track ERC-20 transfer() and transferFrom() calls
        if (data.length >= 68) {
            bytes4 selector = bytes4(data[:4]);
            uint256 transferAmount;
            if (selector == bytes4(0xa9059cbb)) {
                // transfer(address,uint256)
                (, transferAmount) = abi.decode(data[4:], (address, uint256));
            } else if (data.length >= 100 && selector == bytes4(0x23b872dd)) {
                // transferFrom(address,address,uint256)
                (,, transferAmount) = abi.decode(data[4:], (address, address, uint256));
            }

            if (transferAmount > 0) {
                if (knownStablecoins[target]) {
                    // Known stablecoin: normalize to 18 decimals, track against stablecoin cap
                    uint8 decimals = stablecoinDecimals[target];
                    uint256 normalized = decimals < 18
                        ? transferAmount * (10 ** (18 - decimals))
                        : transferAmount;
                    uint256 stableRemaining = dailyStablecoinCap > stablecoinSpentToday
                        ? dailyStablecoinCap - stablecoinSpentToday
                        : 0;
                    if (normalized > stableRemaining) {
                        revert DailyStablecoinCapExceeded(normalized, stableRemaining);
                    }
                    stablecoinSpentToday += normalized;
                    emit StablecoinSpendingTracked(normalized, stablecoinSpentToday, dailyStablecoinCap);
                } else {
                    // Unknown token: add raw amount to ETH counter (conservative)
                    uint256 ethRemaining = dailySpendingCap > spentToday ? dailySpendingCap - spentToday : 0;
                    if (transferAmount > ethRemaining) {
                        revert DailyCapExceeded(transferAmount, ethRemaining);
                    }
                    spentToday += transferAmount;
                    emit SpendingTracked(transferAmount, spentToday, dailySpendingCap);
                }
            }
        }
    }

    function _call(address target, uint256 value, bytes calldata data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
