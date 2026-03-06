// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/shariah/ShariahGuard.sol";

contract ShariahGuardTest is Test {
    ShariahGuard public guard;

    address public shariahBoard = address(0xBEEF);
    address public trader       = address(0xCAFE);
    address public usdc         = address(0xA001);
    address public haram        = address(0xBAD1); // unapproved token
    address public market       = address(0xA001); // same as usdc for market ID

    string constant FATWA_HASH = "ipfs://QmFatwaHashForUSDC";

    function setUp() public {
        guard = new ShariahGuard(shariahBoard);
    }

    // ─────────────────────────────────────────────────────
    // MAX_LEVERAGE is a constant — cannot change
    // ─────────────────────────────────────────────────────

    function test_MaxLeverageIsConstantFive() public {
        assertEq(guard.MAX_LEVERAGE(), 5, "MAX_LEVERAGE must be exactly 5");
    }

    // ─────────────────────────────────────────────────────
    // Asset approval — only Shariah board
    // ─────────────────────────────────────────────────────

    function test_ShariahBoardCanApproveAsset() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        assertTrue(guard.approvedAssets(usdc), "USDC should be approved");
        assertEq(guard.fatwaIPFS(usdc), FATWA_HASH, "Fatwa hash should be stored");
    }

    function test_RandomCallerCannotApproveAsset() public {
        vm.prank(trader);
        vm.expectRevert("ShariahGuard: not Shariah board");
        guard.approveAsset(usdc, FATWA_HASH);
    }

    function test_OwnerCannotApproveAsset() public {
        // There is no "owner" — only shariahMultisig
        address notBoard = address(0x9999);
        vm.prank(notBoard);
        vm.expectRevert("ShariahGuard: not Shariah board");
        guard.approveAsset(usdc, FATWA_HASH);
    }

    function test_CannotApproveWithEmptyFatwaHash() public {
        vm.prank(shariahBoard);
        vm.expectRevert("ShariahGuard: empty fatwa hash");
        guard.approveAsset(usdc, "");
    }

    // ─────────────────────────────────────────────────────
    // Asset revocation
    // ─────────────────────────────────────────────────────

    function test_ShariahBoardCanRevokeAsset() public {
        vm.startPrank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);
        guard.revokeAsset(usdc, "New fatwa prohibits this asset");
        vm.stopPrank();

        assertFalse(guard.approvedAssets(usdc), "USDC should be revoked");
    }

    // ─────────────────────────────────────────────────────
    // Position validation
    // ─────────────────────────────────────────────────────

    function test_ValidPositionPasses() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        // collateral=1000, notional=3000 → leverage=3 (within 5x)
        guard.validatePosition(usdc, 1000e6, 3000e6);
    }

    function test_UnapprovedAssetRejected() public {
        // haram token never approved
        vm.expectRevert("ShariahGuard: asset not approved");
        guard.validatePosition(haram, 1000e6, 2000e6);
    }

    function test_LeverageAboveFiveRejected() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        // collateral=1000, notional=6000 → leverage=6 (exceeds MAX_LEVERAGE=5)
        vm.expectRevert("ShariahGuard: leverage exceeds 5x (maysir)");
        guard.validatePosition(usdc, 1000e6, 6000e6);
    }

    function test_ExactlyFiveLeverageAllowed() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        // collateral=1000, notional=5000 → leverage=5 (exactly at limit)
        guard.validatePosition(usdc, 1000e6, 5000e6);
    }

    function test_ZeroCollateralRejected() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        vm.expectRevert("ShariahGuard: zero collateral");
        guard.validatePosition(usdc, 0, 5000e6);
    }

    // ─────────────────────────────────────────────────────
    // Emergency pause
    // ─────────────────────────────────────────────────────

    function test_ShariahBoardCanPauseMarket() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        vm.prank(shariahBoard);
        guard.emergencyPause(market, "Scholar issued new fatwa");

        vm.expectRevert("ShariahGuard: market paused");
        guard.validatePosition(usdc, 1000e6, 3000e6);
    }

    function test_RandomCallerCannotPauseMarket() public {
        vm.prank(trader);
        vm.expectRevert("ShariahGuard: not Shariah board");
        guard.emergencyPause(market, "hacked");
    }

    function test_ShariahBoardCanUnpauseMarket() public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        vm.startPrank(shariahBoard);
        guard.emergencyPause(market, "Temporary pause");
        guard.unpauseMarket(market);
        vm.stopPrank();

        // Should succeed after unpause
        guard.validatePosition(usdc, 1000e6, 3000e6);
    }

    // ─────────────────────────────────────────────────────
    // Fuzz: leverage always <= 5
    // ─────────────────────────────────────────────────────

    function testFuzz_LeverageAboveFiveAlwaysRejected(uint256 notional) public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        uint256 collateral = 1000e6;
        // Any notional > 5x collateral must revert
        notional = bound(notional, collateral * 6, type(uint128).max);

        vm.expectRevert("ShariahGuard: leverage exceeds 5x (maysir)");
        guard.validatePosition(usdc, collateral, notional);
    }

    function testFuzz_LeverageAtOrBelowFiveAlwaysPasses(uint256 leverageSeed) public {
        vm.prank(shariahBoard);
        guard.approveAsset(usdc, FATWA_HASH);

        uint256 leverage   = bound(leverageSeed, 1, 5);
        uint256 collateral = 1000e6;
        uint256 notional   = collateral * leverage;

        // Must not revert
        guard.validatePosition(usdc, collateral, notional);
    }

    // ─────────────────────────────────────────────────────
    // transferShariahMultisig — coverage tests
    // ─────────────────────────────────────────────────────

    function test_transferShariahMultisig_success() public {
        address newBoard = address(0x7777);
        vm.prank(shariahBoard);
        guard.transferShariahMultisig(newBoard);
        assertEq(guard.shariahMultisig(), newBoard, "multisig should update");
    }

    function test_transferShariahMultisig_onlyBoardReverts() public {
        vm.prank(trader);
        vm.expectRevert("ShariahGuard: not Shariah board");
        guard.transferShariahMultisig(address(0x7777));
    }

    function test_transferShariahMultisig_zeroAddressReverts() public {
        vm.prank(shariahBoard);
        vm.expectRevert("ShariahGuard: zero address");
        guard.transferShariahMultisig(address(0));
    }
}
