// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClawVaultWallet} from "../src/ClawVaultWallet.sol";
import {ClawVaultFactory} from "../src/ClawVaultFactory.sol";
import {P256SignatureVerifier} from "../src/P256Verifier.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Mock P-256 verifier — returns valid (1) for any well-formed 160-byte input.
contract MockP256Verifier {
    fallback(bytes calldata input) external returns (bytes memory) {
        if (input.length < 160) return abi.encode(uint256(0));
        return abi.encode(uint256(1));
    }
}

/// @dev Minimal mock EntryPoint for testing.
contract MockEntryPoint {
    function getUserOpHash(PackedUserOperation calldata) external pure returns (bytes32) {
        return keccak256("test_user_op_hash");
    }

    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external {
        for (uint256 i = 0; i < ops.length; i++) {
            address sender = ops[i].sender;
            bytes32 opHash = keccak256(abi.encode(ops[i].sender, ops[i].nonce, ops[i].callData));
            uint256 result = ClawVaultWallet(payable(sender)).validateUserOp(ops[i], opHash, 0);
            require(result == 0, "Validation failed");
            (bool success,) = sender.call(ops[i].callData);
            require(success, "Execution failed");
        }
        beneficiary;
    }
}

/// @dev Simple ERC-20 mock for stablecoin testing.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    uint8 public decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ClawVaultWalletTest is Test {
    ClawVaultWallet public wallet;
    ClawVaultFactory public factory;
    MockEntryPoint public mockEntryPoint;
    MockERC20 public mockUSDC;

    uint256 constant SIGNER_X = 0x65a2fa44daad46eab0278703edb6c4dcf5e30b8a9aec09fdc71611f6a5fa1a64;
    uint256 constant SIGNER_Y = 0x6e5c8e2e0a27b47d9b6d6e3e8e5e6b5a9c0d2f4e6a8b0c2d4f6e8a0b2c4d6e8a;
    uint256 constant NEW_SIGNER_X = 0x1111111111111111111111111111111111111111111111111111111111111111;
    uint256 constant NEW_SIGNER_Y = 0x2222222222222222222222222222222222222222222222222222222222222222;
    address constant RECOVERY_ADDR = address(0xBEEF);
    uint256 constant DAILY_CAP = 1 ether;
    uint256 constant DAILY_STABLECOIN_CAP = 500e18; // 500 USDC normalized to 18 decimals
    address recipient = address(0xCAFE);

    function setUp() public {
        mockEntryPoint = new MockEntryPoint();

        // Deploy mock P-256 verifier at both precompile and Daimo addresses
        MockP256Verifier verifier = new MockP256Verifier();
        vm.etch(address(0x100), address(verifier).code);
        vm.etch(P256SignatureVerifier.DAIMO_VERIFIER, address(verifier).code);

        // Deploy factory
        factory = new ClawVaultFactory(IEntryPoint(address(mockEntryPoint)));

        // Deploy wallet via factory
        mockUSDC = new MockERC20(6); // USDC has 6 decimals
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;

        wallet = factory.createAccount(
            SIGNER_X, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP,
            stablecoins, stablecoinDecs, true, bytes32(0)
        );

        // Fund wallet
        vm.deal(address(wallet), 10 ether);
    }

    // ─── Initialization ───────────────────────────────────────────────────
    function test_InitializeSetsState() public view {
        assertEq(wallet.signerX(), SIGNER_X);
        assertEq(wallet.signerY(), SIGNER_Y);
        assertEq(wallet.recoveryAddress(), RECOVERY_ADDR);
        assertEq(wallet.dailySpendingCap(), DAILY_CAP);
        assertEq(wallet.dailyStablecoinCap(), DAILY_STABLECOIN_CAP);
        assertTrue(wallet.knownStablecoins(address(mockUSDC)));
        assertEq(wallet.stablecoinDecimals(address(mockUSDC)), 6);
        assertTrue(wallet.usePrecompile());
        assertFalse(wallet.frozen());
    }

    // ─── Execution ────────────────────────────────────────────────────────
    function test_ExecuteTransfer() public {
        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, 0.1 ether, "");
        assertEq(recipient.balance, 0.1 ether);
    }

    function test_ExecuteOnlyEntryPoint() public {
        vm.expectRevert(ClawVaultWallet.OnlyEntryPoint.selector);
        wallet.execute(recipient, 0.1 ether, "");
    }

    function test_ExecuteBatch() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);
        targets[0] = recipient;
        targets[1] = address(0xBEAD);
        values[0] = 0.05 ether;
        values[1] = 0.05 ether;
        datas[0] = "";
        datas[1] = "";

        vm.prank(address(mockEntryPoint));
        wallet.executeBatch(targets, values, datas);
        assertEq(recipient.balance, 0.05 ether);
        assertEq(address(0xBEAD).balance, 0.05 ether);
    }

    // ─── ETH Spending Cap ─────────────────────────────────────────────────
    function test_SpendingCapEnforced() public {
        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, DAILY_CAP, "");

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(abi.encodeWithSelector(ClawVaultWallet.DailyCapExceeded.selector, 1, 0));
        wallet.execute(recipient, 1, "");
    }

    function test_SpendingCapDailyReset() public {
        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, DAILY_CAP / 2, "");

        vm.warp(block.timestamp + 1 days);

        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, DAILY_CAP, "");
    }

    // ─── Stablecoin Spending Cap (Separate Counter) ───────────────────────
    function test_StablecoinCapSeparateFromEthCap() public {
        mockUSDC.mint(address(wallet), 1000e6);

        // Spend full ETH cap
        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, DAILY_CAP, "");
        assertEq(wallet.spentToday(), DAILY_CAP);

        // Stablecoin transfer should still succeed (separate counter)
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, 100e6); // 100 USDC
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);

        // 100 USDC * 10^12 = 100e18 normalized
        assertEq(wallet.stablecoinSpentToday(), 100e18);
        // ETH counter unchanged
        assertEq(wallet.spentToday(), DAILY_CAP);
    }

    function test_StablecoinCapNormalizesDecimals() public {
        mockUSDC.mint(address(wallet), 1000e6);

        // Transfer 100 USDC (100_000_000 raw with 6 decimals)
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, 100e6);
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);

        // Should be normalized to 18 decimals: 100e6 * 10^12 = 100e18
        assertEq(wallet.stablecoinSpentToday(), 100e18);
    }

    function test_StablecoinCapExceeded() public {
        mockUSDC.mint(address(wallet), 10000e6);

        // Spend 500 USDC (= full stablecoin cap at 500e18 normalized)
        bytes memory data1 = abi.encodeWithSelector(0xa9059cbb, recipient, 500e6);
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data1);
        assertEq(wallet.stablecoinSpentToday(), 500e18);

        // Try to spend 1 more USDC — should fail
        bytes memory data2 = abi.encodeWithSelector(0xa9059cbb, recipient, 1e6);
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(abi.encodeWithSelector(ClawVaultWallet.DailyStablecoinCapExceeded.selector, 1e18, 0));
        wallet.execute(address(mockUSDC), 0, data2);
    }

    function test_StablecoinCapDailyReset() public {
        mockUSDC.mint(address(wallet), 10000e6);

        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, 500e6);
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);
        assertEq(wallet.stablecoinSpentToday(), 500e18);

        // Next day — counter resets
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);
        assertEq(wallet.stablecoinSpentToday(), 500e18); // Reset then added 500e18
    }

    function test_SpendingCapTracksERC20Transfers() public {
        // Known stablecoin → tracks in stablecoin counter
        mockUSDC.mint(address(wallet), 1000e6);
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, 500e6);

        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);
        // Stablecoin tracked in stablecoin counter, NOT in ETH counter
        assertEq(wallet.stablecoinSpentToday(), 500e18);
        assertEq(wallet.spentToday(), 0);
    }

    function test_SpendingCapCombinedETHAndERC20() public {
        // Unknown ERC-20 (not a stablecoin) → tracks in ETH counter
        MockERC20 unknownToken = new MockERC20(18);
        unknownToken.mint(address(wallet), 1000 ether);

        // Spend half cap as ETH
        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, DAILY_CAP / 2, "");

        // Try to spend remaining + 1 as unknown ERC20 — should fail (uses ETH counter)
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, (DAILY_CAP / 2) + 1);
        vm.prank(address(mockEntryPoint));
        vm.expectRevert();
        wallet.execute(address(unknownToken), 0, data);
    }

    function test_SpendingCapExceededByERC20() public {
        // Unknown token → counted against ETH cap
        MockERC20 unknownToken = new MockERC20(18);
        unknownToken.mint(address(wallet), 1000 ether);
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, DAILY_CAP + 1);

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(abi.encodeWithSelector(ClawVaultWallet.DailyCapExceeded.selector, DAILY_CAP + 1, DAILY_CAP));
        wallet.execute(address(unknownToken), 0, data);
    }

    // ─── Freeze ───────────────────────────────────────────────────────────
    function test_FreezeByRecovery() public {
        vm.prank(RECOVERY_ADDR);
        wallet.freeze();
        assertTrue(wallet.frozen());
    }

    function test_FreezeBlocksExecution() public {
        vm.prank(RECOVERY_ADDR);
        wallet.freeze();

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(ClawVaultWallet.WalletFrozen.selector);
        wallet.execute(recipient, 0.1 ether, "");
    }

    function test_FreezeBlocksBatchExecution() public {
        vm.prank(RECOVERY_ADDR);
        wallet.freeze();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = recipient;
        values[0] = 0.1 ether;
        datas[0] = "";

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(ClawVaultWallet.WalletFrozen.selector);
        wallet.executeBatch(targets, values, datas);
    }

    function test_FreezeBySelfCall() public {
        // Signer freezes via UserOp → execute → self-call to freeze()
        bytes memory freezeCall = abi.encodeWithSelector(ClawVaultWallet.freeze.selector);
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(wallet), 0, freezeCall);
        assertTrue(wallet.frozen());
    }

    function test_FreezeNotByEntryPoint() public {
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(ClawVaultWallet.OnlyRecoveryOrSigner.selector);
        wallet.freeze();
    }

    function test_FreezeNotByRandom() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ClawVaultWallet.OnlyRecoveryOrSigner.selector);
        wallet.freeze();
    }

    // ─── Unfreeze ─────────────────────────────────────────────────────────
    function test_UnfreezeFlow() public {
        vm.prank(RECOVERY_ADDR);
        wallet.freeze();

        vm.prank(RECOVERY_ADDR);
        wallet.requestUnfreeze();

        // Too early
        vm.prank(RECOVERY_ADDR);
        vm.expectRevert(ClawVaultWallet.UnfreezeNotReady.selector);
        wallet.finalizeUnfreeze();

        vm.warp(block.timestamp + 10 minutes + 1);

        vm.prank(RECOVERY_ADDR);
        wallet.finalizeUnfreeze();
        assertFalse(wallet.frozen());
    }

    function test_UnfreezeOnlyRecovery() public {
        vm.prank(RECOVERY_ADDR);
        wallet.freeze();

        vm.prank(address(0xDEAD));
        vm.expectRevert(ClawVaultWallet.OnlyRecovery.selector);
        wallet.requestUnfreeze();
    }

    function test_FinalizeUnfreezeRequiresRequest() public {
        vm.prank(RECOVERY_ADDR);
        vm.expectRevert(ClawVaultWallet.NoUnfreezeRequested.selector);
        wallet.finalizeUnfreeze();
    }

    // ─── Key Rotation ─────────────────────────────────────────────────────
    function test_KeyRotationFullFlow() public {
        vm.prank(RECOVERY_ADDR);
        wallet.initiateKeyRotation(NEW_SIGNER_X, NEW_SIGNER_Y);

        assertTrue(wallet.frozen());
        assertEq(wallet.pendingSignerX(), NEW_SIGNER_X);
        assertEq(wallet.pendingSignerY(), NEW_SIGNER_Y);

        vm.prank(RECOVERY_ADDR);
        vm.expectRevert(ClawVaultWallet.RecoveryNotReady.selector);
        wallet.finalizeKeyRotation();

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(RECOVERY_ADDR);
        wallet.finalizeKeyRotation();
        assertEq(wallet.signerX(), NEW_SIGNER_X);
        assertEq(wallet.signerY(), NEW_SIGNER_Y);
        assertTrue(wallet.frozen()); // Still frozen — unfreeze is separate
    }

    function test_KeyRotationOnlyRecovery() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ClawVaultWallet.OnlyRecovery.selector);
        wallet.initiateKeyRotation(NEW_SIGNER_X, NEW_SIGNER_Y);
    }

    function test_FinalizeRotationNoPending() public {
        vm.prank(RECOVERY_ADDR);
        vm.expectRevert(ClawVaultWallet.NoPendingRotation.selector);
        wallet.finalizeKeyRotation();
    }

    // ─── P-256 Signature Validation ───────────────────────────────────────
    function test_ValidateUserOpAcceptsValidSig() public {
        PackedUserOperation memory userOp = _buildUserOp(
            abi.encodeWithSelector(ClawVaultWallet.execute.selector, recipient, 0.01 ether, "")
        );
        userOp.signature = abi.encode(uint256(1), uint256(2));

        bytes32 opHash = keccak256("test");
        vm.prank(address(mockEntryPoint));
        uint256 result = wallet.validateUserOp(userOp, opHash, 0);
        assertEq(result, 0);
    }

    function test_ValidateUserOpRejectsWrongLength() public {
        PackedUserOperation memory userOp = _buildUserOp(
            abi.encodeWithSelector(ClawVaultWallet.execute.selector, recipient, 0.01 ether, "")
        );
        userOp.signature = hex"aabbcc";

        bytes32 opHash = keccak256("test");
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(ClawVaultWallet.InvalidSignatureLength.selector);
        wallet.validateUserOp(userOp, opHash, 0);
    }

    function test_ValidateUserOpRejectsHighS() public {
        uint256 P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
        uint256 highS = (P256_N / 2) + 1;

        PackedUserOperation memory userOp = _buildUserOp(
            abi.encodeWithSelector(ClawVaultWallet.execute.selector, recipient, 0.01 ether, "")
        );
        userOp.signature = abi.encode(uint256(1), highS);

        bytes32 opHash = keccak256("test");
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(P256SignatureVerifier.SignatureHighS.selector);
        wallet.validateUserOp(userOp, opHash, 0);
    }

    // ─── ERC-1271 ─────────────────────────────────────────────────────────
    function test_IsValidSignature() public view {
        bytes32 hash = keccak256("test message");
        bytes memory sig = abi.encode(uint256(1), uint256(2));
        assertEq(wallet.isValidSignature(hash, sig), bytes4(0x1626ba7e));
    }

    function test_IsValidSignatureInvalidLength() public view {
        bytes32 hash = keccak256("test message");
        assertEq(wallet.isValidSignature(hash, hex"aabb"), bytes4(0xffffffff));
    }

    // ─── Spending Cap Admin (Recovery-Only) ────────────────────────────
    function test_SetDailyCapRejectsDirectCall() public {
        vm.expectRevert(ClawVaultWallet.OnlyRecovery.selector);
        wallet.setDailyCap(2 ether);
    }

    function test_SetStablecoinRejectsDirectCall() public {
        vm.expectRevert(ClawVaultWallet.OnlyRecovery.selector);
        wallet.setStablecoin(address(0x1234), true, 18);
    }

    function test_SetDailyStablecoinCapRejectsDirectCall() public {
        vm.expectRevert(ClawVaultWallet.OnlyRecovery.selector);
        wallet.setDailyStablecoinCap(1000e18);
    }

    // ─── Receive ETH ──────────────────────────────────────────────────────
    function test_ReceiveETH() public {
        uint256 before_ = address(wallet).balance;
        vm.deal(address(this), 1 ether);
        (bool success,) = payable(address(wallet)).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(wallet).balance, before_ + 1 ether);
    }

    // ─── Factory ──────────────────────────────────────────────────────────
    function test_FactoryDeterministicAddress() public view {
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        address predicted = factory.getAddress(SIGNER_X, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(0));
        assertEq(predicted, address(wallet));
    }

    function test_FactoryCannotRedeployDuplicate() public {
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        vm.expectRevert(ClawVaultFactory.WalletAlreadyDeployed.selector);
        factory.createAccount(SIGNER_X, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(0));
    }

    function test_FactoryDifferentSaltDifferentAddress() public view {
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        address addr1 = factory.getAddress(SIGNER_X, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(0));
        address addr2 = factory.getAddress(SIGNER_X, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(uint256(1)));
        assertTrue(addr1 != addr2);
    }

    // ─── Events ───────────────────────────────────────────────────────────
    function test_FreezeEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ClawVaultWallet.Frozen(RECOVERY_ADDR);
        vm.prank(RECOVERY_ADDR);
        wallet.freeze();
    }

    function test_ExecuteEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ClawVaultWallet.Executed(recipient, 0.01 ether, "");
        vm.prank(address(mockEntryPoint));
        wallet.execute(recipient, 0.01 ether, "");
    }

    // ─── Constants ────────────────────────────────────────────────────────
    function test_RecoveryDelayIs48Hours() public view {
        assertEq(wallet.RECOVERY_DELAY(), 48 hours);
    }

    function test_UnfreezeDelayIs10Minutes() public view {
        assertEq(wallet.UNFREEZE_DELAY(), 10 minutes);
    }

    // ─── PaymasterAndData ─────────────────────────────────────────────────
    function test_RejectsNonEmptyPaymasterAndData() public {
        PackedUserOperation memory userOp = _buildUserOp(
            abi.encodeWithSelector(ClawVaultWallet.execute.selector, recipient, 0.01 ether, "")
        );
        userOp.signature = abi.encode(uint256(1), uint256(2));
        userOp.paymasterAndData = hex"deadbeef";

        bytes32 opHash = keccak256("test");
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(ClawVaultWallet.NoPaymastersAllowed.selector);
        wallet.validateUserOp(userOp, opHash, 0);
    }

    // ─── Key Rotation Validation ─────────────────────────────────────────
    function test_KeyRotationRejectsZeroX() public {
        vm.prank(RECOVERY_ADDR);
        vm.expectRevert(ClawVaultWallet.InvalidPublicKey.selector);
        wallet.initiateKeyRotation(0, NEW_SIGNER_Y);
    }

    function test_KeyRotationRejectsZeroY() public {
        vm.prank(RECOVERY_ADDR);
        vm.expectRevert(ClawVaultWallet.InvalidPublicKey.selector);
        wallet.initiateKeyRotation(NEW_SIGNER_X, 0);
    }

    // ─── Self-Call Cannot Modify Caps (Recovery-Only) ──────────────────
    function test_SetDailyCapViaSelfCallReverts() public {
        bytes memory callData = abi.encodeWithSelector(ClawVaultWallet.setDailyCap.selector, 2 ether);
        vm.prank(address(mockEntryPoint));
        vm.expectRevert();
        wallet.execute(address(wallet), 0, callData);
    }

    function test_SetStablecoinViaSelfCallReverts() public {
        address newStable = address(0x5555);
        bytes memory callData = abi.encodeWithSelector(ClawVaultWallet.setStablecoin.selector, newStable, true, uint8(18));
        vm.prank(address(mockEntryPoint));
        vm.expectRevert();
        wallet.execute(address(wallet), 0, callData);
    }

    // ─── Recovery Address Can Modify Caps ────────────────────────────────
    function test_SetDailyCapByRecovery() public {
        vm.prank(RECOVERY_ADDR);
        wallet.setDailyCap(2 ether);
        assertEq(wallet.dailySpendingCap(), 2 ether);
    }

    function test_SetStablecoinByRecovery() public {
        address newStable = address(0x5555);
        vm.prank(RECOVERY_ADDR);
        wallet.setStablecoin(newStable, true, 18);
        assertTrue(wallet.knownStablecoins(newStable));
        assertEq(wallet.stablecoinDecimals(newStable), 18);
    }

    function test_SetDailyStablecoinCapByRecovery() public {
        vm.prank(RECOVERY_ADDR);
        wallet.setDailyStablecoinCap(1000e18);
        assertEq(wallet.dailyStablecoinCap(), 1000e18);
    }

    // ─── Zero Value ERC-20 Transfer ──────────────────────────────────────
    function test_ZeroValueERC20TransferDoesNotRevert() public {
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, recipient, uint256(0));
        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);
        assertEq(wallet.stablecoinSpentToday(), 0);
    }

    // ─── Daimo Fallback Path ─────────────────────────────────────────────
    function test_DaimoFallbackVerifiesSignature() public {
        // Deploy a wallet with usePrecompile=false
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        ClawVaultWallet fallbackWallet = factory.createAccount(
            SIGNER_X, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP,
            stablecoins, stablecoinDecs, false, bytes32(uint256(99))
        );
        vm.deal(address(fallbackWallet), 10 ether);
        assertFalse(fallbackWallet.usePrecompile());

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(fallbackWallet),
            nonce: 0,
            initCode: "",
            callData: abi.encodeWithSelector(ClawVaultWallet.execute.selector, recipient, 0.01 ether, ""),
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: abi.encode(uint256(1), uint256(2))
        });

        bytes32 opHash = keccak256("test_daimo");
        vm.prank(address(mockEntryPoint));
        uint256 result = fallbackWallet.validateUserOp(userOp, opHash, 0);
        assertEq(result, 0);
    }

    // ─── transferFrom Spending Cap ──────────────────────────────────────
    function test_SpendingCapTracksTransferFrom() public {
        mockUSDC.mint(address(wallet), 1000e6);
        bytes memory data = abi.encodeWithSelector(0x23b872dd, address(wallet), recipient, 500e6);

        vm.prank(address(mockEntryPoint));
        wallet.execute(address(mockUSDC), 0, data);
        // Known stablecoin → stablecoin counter
        assertEq(wallet.stablecoinSpentToday(), 500e18);
    }

    function test_SpendingCapExceededByTransferFrom() public {
        mockUSDC.mint(address(wallet), 10000e6);
        // 501 USDC normalized = 501e18 > 500e18 cap
        bytes memory data = abi.encodeWithSelector(0x23b872dd, address(wallet), recipient, 501e6);

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(abi.encodeWithSelector(ClawVaultWallet.DailyStablecoinCapExceeded.selector, 501e18, DAILY_STABLECOIN_CAP));
        wallet.execute(address(mockUSDC), 0, data);
    }

    // ─── Zero Recovery Address ──────────────────────────────────────────
    function test_RejectsZeroRecoveryAddress() public {
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        vm.expectRevert(ClawVaultWallet.InvalidRecoveryAddress.selector);
        factory.createAccount(SIGNER_X, SIGNER_Y, address(0), DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(uint256(42)));
    }

    function test_RejectsZeroSignerX() public {
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        vm.expectRevert(ClawVaultWallet.InvalidPublicKey.selector);
        factory.createAccount(0, SIGNER_Y, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(uint256(43)));
    }

    function test_RejectsZeroSignerY() public {
        address[] memory stablecoins = new address[](1);
        stablecoins[0] = address(mockUSDC);
        uint8[] memory stablecoinDecs = new uint8[](1);
        stablecoinDecs[0] = 6;
        vm.expectRevert(ClawVaultWallet.InvalidPublicKey.selector);
        factory.createAccount(SIGNER_X, 0, RECOVERY_ADDR, DAILY_CAP, DAILY_STABLECOIN_CAP, stablecoins, stablecoinDecs, true, bytes32(uint256(44)));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────
    function _buildUserOp(bytes memory callData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(wallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }
}
