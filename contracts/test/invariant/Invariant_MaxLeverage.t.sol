// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/shariah/ShariahGuard.sol";

// ══════════════════════════════════════════════════════════════
//  HANDLER
// ══════════════════════════════════════════════════════════════

/**
 * @notice Handler for ShariahGuard invariant testing.
 *
 * Ghost accounting:
 *   - `successfulValidations`   — count of positions that passed validatePosition()
 *   - `maxLeverageSucceeded`    — highest leverage that was ever accepted
 *   - `attemptedAbove5`         — count of attempts with leverage > 5
 *   - `rejectedAbove5`          — count of rejections where leverage > 5
 */
contract ShariahGuardHandler is Test {
    ShariahGuard public guard;
    address       public multisig;

    // Ghost accounting
    uint256 public successfulValidations;
    uint256 public maxLeverageSucceeded;    // must never exceed 5
    uint256 public attemptedAbove5;
    uint256 public rejectedAbove5;
    uint256 public rejectedBelowOrEqual5;  // should be rare (other validation reasons)

    // Approved test asset
    address public asset;

    constructor(ShariahGuard _guard, address _multisig, address _asset) {
        guard    = _guard;
        multisig = _multisig;
        asset    = _asset;
    }

    // ─────────────────────────────────────────────────────
    // Handler: attempt validatePosition with arbitrary leverage
    // ─────────────────────────────────────────────────────

    /**
     * @notice Attempt to open a position with fuzz-generated leverage.
     *         Records whether it succeeded and at what leverage.
     *
     * @param collateralSeed  Fuzz seed for collateral amount.
     * @param leverageSeed    Fuzz seed for leverage (1 to 20 — includes illegal range).
     */
    function tryValidatePosition(uint256 collateralSeed, uint256 leverageSeed) external {
        uint256 collateral = bound(collateralSeed, 1, 1_000_000e6);  // 1 to 1M USDC-units
        uint256 leverage   = bound(leverageSeed,   1, 20);           // includes illegal 6–20

        uint256 notional = collateral * leverage;

        if (leverage > 5) {
            attemptedAbove5++;
            try guard.validatePosition(asset, collateral, notional) {
                // This must NEVER succeed — record it for the invariant assertion
                successfulValidations++;
                if (leverage > maxLeverageSucceeded) maxLeverageSucceeded = leverage;
            } catch {
                rejectedAbove5++;
            }
        } else {
            // Leverage 1–5 should succeed (asset is approved, prices valid)
            try guard.validatePosition(asset, collateral, notional) {
                successfulValidations++;
                if (leverage > maxLeverageSucceeded) maxLeverageSucceeded = leverage;
            } catch {
                // Acceptable: could revert for other Shariah reasons (market paused, etc.)
                rejectedBelowOrEqual5++;
            }
        }
    }

    /**
     * @notice Attempt with exact leverage = 6 (one over the limit).
     *         Must always revert.
     */
    function tryExactlyLeverage6(uint256 collateralSeed) external {
        uint256 collateral = bound(collateralSeed, 1, 1_000_000e6);
        uint256 notional   = collateral * 6;

        attemptedAbove5++;
        try guard.validatePosition(asset, collateral, notional) {
            successfulValidations++;
            if (uint256(6) > maxLeverageSucceeded) maxLeverageSucceeded = 6;
        } catch {
            rejectedAbove5++;
        }
    }

    /**
     * @notice Attempt with extreme leverage (10x, 20x).
     *         Must always revert.
     */
    function tryHighLeverage(uint256 collateralSeed, uint256 leverageSeed) external {
        uint256 collateral = bound(collateralSeed, 1, 1_000_000e6);
        uint256 leverage   = bound(leverageSeed, 6, 1000); // definitely above limit
        uint256 notional   = collateral * leverage;

        attemptedAbove5++;
        try guard.validatePosition(asset, collateral, notional) {
            successfulValidations++;
            if (leverage > maxLeverageSucceeded) maxLeverageSucceeded = leverage;
        } catch {
            rejectedAbove5++;
        }
    }

    /**
     * @notice Attempt with minimum valid leverage = 1.
     *         Should always succeed (asset approved, collateral > 0).
     */
    function tryLeverage1(uint256 collateralSeed) external {
        uint256 collateral = bound(collateralSeed, 1, 1_000_000e6);
        // notional = collateral * 1 = collateral (notional >= collateral passes the notional check)
        try guard.validatePosition(asset, collateral, collateral) {
            successfulValidations++;
            if (uint256(1) > maxLeverageSucceeded) maxLeverageSucceeded = 1;
        } catch {
            rejectedBelowOrEqual5++;
        }
    }

    /**
     * @notice Attempt to pause the market (Shariah board action).
     *         Tests that pausing doesn't break the leverage invariant.
     */
    function pauseMarket(bool doPause) external {
        vm.startPrank(multisig);
        if (doPause) {
            guard.emergencyPause(asset, "invariant test pause");
        } else {
            guard.unpauseMarket(asset);
        }
        vm.stopPrank();
    }
}

// ══════════════════════════════════════════════════════════════
//  INVARIANT TEST
// ══════════════════════════════════════════════════════════════

/**
 * @title Invariant_MaxLeverage
 * @notice Proves that ShariahGuard enforces the immutable 5x leverage ceiling
 *         under all possible conditions.
 *
 *   INVARIANT 1: ShariahGuard.MAX_LEVERAGE is always exactly 5.
 *     Rationale: MAX_LEVERAGE is a Solidity constant — it cannot be changed by
 *     the owner, the Shariah board, or any governance action. This invariant
 *     verifies the constant is still 5 after any sequence of handler calls.
 *
 *   INVARIANT 2: validatePosition() never succeeds when leverage > 5.
 *     Rationale: The Shariah prohibition of maysir (excessive speculation) is
 *     enforced on every position open. No actor — trader, keeper, governance —
 *     can open a position with leverage > 5.
 *
 *   INVARIANT 3: Every position that passed validatePosition had leverage <= 5.
 *     Rationale: Ghost accounting tracks the maximum leverage that was ever
 *     accepted. It must never exceed 5.
 *
 * Islamic finance basis: ShariahGuard.validatePosition() is called by PositionManager
 * before every openPosition() — no exceptions. MAX_LEVERAGE = 5 is immutable.
 */
contract Invariant_MaxLeverage is Test {
    ShariahGuard        public guard;
    ShariahGuardHandler public handler;

    address public multisig = address(0xBEEF);
    address public asset    = address(0x1234); // arbitrary approved market ID

    function setUp() public {
        // Deploy ShariahGuard with the Shariah board multisig
        guard = new ShariahGuard(multisig);

        // Approve the test asset (simulates a board-approved halal asset with fatwa)
        vm.prank(multisig);
        guard.approveAsset(asset, "ipfs://QmTestFatwaHashForInvariantTesting");

        // Deploy handler
        handler = new ShariahGuardHandler(guard, multisig, asset);

        // Direct the fuzzer to only call the handler
        targetContract(address(handler));
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 1: MAX_LEVERAGE constant is always 5
    // ─────────────────────────────────────────────────────

    /**
     * @notice MAX_LEVERAGE is a constant — it must always equal 5.
     *         No governance action, no owner call, no upgrade can change it.
     *         (Non-upgradeable contract, no setter function exists.)
     */
    function invariant_maxLeverageConstantIsAlwaysFive() public view {
        assertEq(
            guard.MAX_LEVERAGE(),
            5,
            "MAYSIR VIOLATION: MAX_LEVERAGE constant has been changed from 5"
        );
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 2: validatePosition never succeeds with leverage > 5
    // ─────────────────────────────────────────────────────

    /**
     * @notice Every position that successfully passed validatePosition had leverage <= 5.
     *         Tracked via ghost variable handler.maxLeverageSucceeded.
     */
    function invariant_noPositionEverOpenedWithLeverageAbove5() public view {
        assertLe(
            handler.maxLeverageSucceeded(),
            5,
            "MAYSIR VIOLATION: validatePosition succeeded with leverage > 5"
        );
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 3: All leverage > 5 attempts are rejected
    // ─────────────────────────────────────────────────────

    /**
     * @notice Every attempt with leverage > 5 must be rejected.
     *         If any slipped through, rejectedAbove5 < attemptedAbove5.
     */
    function invariant_allAbove5AttemptsRejected() public view {
        assertEq(
            handler.attemptedAbove5(),
            handler.rejectedAbove5(),
            "MAYSIR VIOLATION: some leverage>5 attempt was not rejected"
        );
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 4: Structural — asset approval requires fatwa
    // ─────────────────────────────────────────────────────

    /**
     * @notice The test asset is approved with a fatwa IPFS hash.
     *         approvedAssets[asset] must remain true unless the Shariah board revokes it.
     *         (We don't revoke in this handler, so it must stay approved.)
     */
    function invariant_approvedAssetRetainsFatwa() public view {
        // Asset is approved at setup; handler never calls revokeAsset
        assertTrue(
            guard.approvedAssets(asset),
            "Asset approval was lost without a revoke call"
        );
        assertTrue(
            bytes(guard.fatwaIPFS(asset)).length > 0,
            "Fatwa IPFS hash was cleared without revoking"
        );
    }
}
