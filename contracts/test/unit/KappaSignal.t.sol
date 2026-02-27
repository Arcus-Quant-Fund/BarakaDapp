// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracle/OracleAdapter.sol";
import "../mocks/MockERC20.sol";

/**
 * @title KappaSignalTest
 * @notice Unit tests for OracleAdapter.getPremium() and getKappaSignal().
 *
 * Tests verify:
 * - getPremium: correct sign and magnitude for premium/discount/parity
 * - getKappaSignal: risk regime classification
 * - getKappaSignal: positive κ when basis is converging
 * - getKappaSignal: negative κ when basis is diverging
 * - getKappaSignal: κ = 0 when insufficient TWAP history
 * - getKappaSignal: κ = 0 when P_old is negligible (< 1bps)
 * - KappaAlert emitted by snapshotPrice when regime >= HIGH
 * - fuzz: regime always 0-3, |premium| ≤ circuit-breaker ceiling
 */
contract KappaSignalTest is Test {
    OracleAdapter public adapter;

    address public owner  = address(0xABCD);
    address public asset  = address(0x1234);

    // Minimal Chainlink mock (returns fixed price, never stale)
    MockFeed public feedA;
    MockFeed public feedB;

    uint256 constant BASE = 50_000e18; // $50k index

    function setUp() public {
        vm.startPrank(owner);
        adapter = new OracleAdapter(owner);
        feedA   = new MockFeed(BASE, 8);   // normalised to 1e18 internally
        feedB   = new MockFeed(BASE, 8);
        // Feeds return BASE already in 8-decimal feed format; OracleAdapter scales to 1e18
        // So feed answer = BASE / 1e10 = 5_000_000 (Chainlink ETH/USD 8-dec format)
        uint256 feedAnswer = BASE / 1e10;
        feedA.setAnswer(int256(feedAnswer));
        feedB.setAnswer(int256(feedAnswer));
        adapter.setOracle(asset, address(feedA), address(feedB));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // getPremium — basic cases
    // ─────────────────────────────────────────────────────

    function test_PremiumZeroAtParity() public {
        // No TWAP obs → falls back to index price → mark = index → F = 0
        int256 p = adapter.getPremium(asset);
        assertEq(p, 0, "Premium must be 0 at parity");
    }

    function test_PremiumPositiveWhenMarkAboveIndex() public {
        // Push a TWAP obs 0.5% above index
        uint256 markUp = BASE + BASE / 200; // +0.5%
        adapter.recordMarkPrice(asset, markUp);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, markUp);

        int256 p = adapter.getPremium(asset);
        assertGt(p, 0, "Premium must be positive when mark > index");
        // Expected ≈ 0.5% = 5e15
        assertApproxEqAbs(p, 5e15, 1e13, "Premium ~50bps");
    }

    function test_PremiumNegativeWhenMarkBelowIndex() public {
        uint256 markDown = BASE - BASE / 200; // -0.5%
        adapter.recordMarkPrice(asset, markDown);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, markDown);

        int256 p = adapter.getPremium(asset);
        assertLt(p, 0, "Premium must be negative when mark < index");
    }

    // ─────────────────────────────────────────────────────
    // getKappaSignal — regime classification
    // ─────────────────────────────────────────────────────

    function test_RegimeNormalAtParity() public {
        (, , uint8 regime) = adapter.getKappaSignal(asset);
        assertEq(regime, 0, "Regime must be NORMAL at parity");
    }

    function test_RegimeElevated() public {
        // Push mark 20bps above index
        uint256 mark20 = BASE + BASE * 20 / 10000;
        adapter.recordMarkPrice(asset, mark20);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, mark20);

        (, , uint8 regime) = adapter.getKappaSignal(asset);
        assertEq(regime, 1, "Regime must be ELEVATED at 20bps");
    }

    function test_RegimeHigh() public {
        // Push mark 50bps above index (between 40 and 60)
        uint256 mark50 = BASE + BASE * 50 / 10000;
        adapter.recordMarkPrice(asset, mark50);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, mark50);

        (, , uint8 regime) = adapter.getKappaSignal(asset);
        assertEq(regime, 2, "Regime must be HIGH at 50bps");
    }

    function test_RegimeCritical() public {
        // Push mark 65bps above index (≥60bps)
        uint256 mark65 = BASE + BASE * 65 / 10000;
        adapter.recordMarkPrice(asset, mark65);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, mark65);

        (, , uint8 regime) = adapter.getKappaSignal(asset);
        assertEq(regime, 3, "Regime must be CRITICAL at 65bps");
    }

    // ─────────────────────────────────────────────────────
    // getKappaSignal — κ estimate
    // ─────────────────────────────────────────────────────

    function test_KappaZeroWithOnlyOneObservation() public {
        adapter.recordMarkPrice(asset, BASE + BASE / 100); // single obs
        (int256 k, , ) = adapter.getKappaSignal(asset);
        assertEq(k, 0, "kappa must be 0 with < 2 observations");
    }

    function test_KappaPositiveWhenBasisConverging() public {
        // Simulate basis shrinking: 50bps → 30bps over 600s
        uint256 mark50 = BASE + BASE * 50 / 10000;
        uint256 mark30 = BASE + BASE * 30 / 10000;
        uint256 feedAnswer = BASE / 1e10;

        adapter.recordMarkPrice(asset, mark50); // obs[0] = older, higher premium
        vm.warp(block.timestamp + 600);
        feedA.setAnswer(int256(feedAnswer)); // refresh staleness after warp
        feedB.setAnswer(int256(feedAnswer));
        adapter.recordMarkPrice(asset, mark30); // obs[1] = newer, lower premium

        (int256 k, , ) = adapter.getKappaSignal(asset);
        assertGt(k, 0, "kappa must be positive when basis shrinking");
    }

    function test_KappaNegativeWhenBasisDiverging() public {
        // Simulate basis growing: 20bps → 50bps over 600s
        uint256 mark20 = BASE + BASE * 20 / 10000;
        uint256 mark50 = BASE + BASE * 50 / 10000;
        uint256 feedAnswer = BASE / 1e10;

        adapter.recordMarkPrice(asset, mark20); // obs[0] = older, lower premium
        vm.warp(block.timestamp + 600);
        feedA.setAnswer(int256(feedAnswer)); // refresh staleness after warp
        feedB.setAnswer(int256(feedAnswer));
        adapter.recordMarkPrice(asset, mark50); // obs[1] = newer, higher premium

        (int256 k, , ) = adapter.getKappaSignal(asset);
        assertLt(k, 0, "kappa must be negative when basis growing");
    }

    function test_KappaZeroWhenP_oldNegligible() public {
        // P_old < 1bps — κ is undefined (basis already near zero)
        uint256 markTiny = BASE + BASE * 5 / 1000000; // 0.0005% = 0.5bps
        adapter.recordMarkPrice(asset, markTiny);
        vm.warp(block.timestamp + 60);
        adapter.recordMarkPrice(asset, markTiny + 1e14);

        (int256 k, , ) = adapter.getKappaSignal(asset);
        assertEq(k, 0, "kappa must be 0 when P_old < KAPPA_MIN_PREMIUM");
    }

    function test_KappaSymmetricForDiscountSide() public {
        // Discount shrinking: -50bps → -30bps (basis converging from below)
        uint256 mark_50 = BASE - BASE * 50 / 10000;
        uint256 mark_30 = BASE - BASE * 30 / 10000;
        uint256 feedAnswer = BASE / 1e10;

        adapter.recordMarkPrice(asset, mark_50);
        vm.warp(block.timestamp + 600);
        feedA.setAnswer(int256(feedAnswer)); // refresh staleness after warp
        feedB.setAnswer(int256(feedAnswer));
        adapter.recordMarkPrice(asset, mark_30);

        (int256 k, , ) = adapter.getKappaSignal(asset);
        assertGt(k, 0, "kappa must be positive when discount is shrinking");
    }

    // ─────────────────────────────────────────────────────
    // KappaAlert event
    // ─────────────────────────────────────────────────────

    function test_KappaAlertEmittedWhenRegimeHigh() public {
        // Set mark 50bps above index, then snapshotPrice should emit KappaAlert
        uint256 mark50 = BASE + BASE * 50 / 10000;
        adapter.recordMarkPrice(asset, mark50);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, mark50);

        vm.expectEmit(true, false, false, false);
        emit OracleAdapter.KappaAlert(asset, 2, 0, 0); // regime=2; other args loose

        vm.prank(owner);
        adapter.snapshotPrice(asset);
    }

    function test_KappaAlertNotEmittedWhenNormal() public {
        // At parity (regime=0), no alert expected
        vm.recordLogs();
        vm.prank(owner);
        adapter.snapshotPrice(asset);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 alertTopic = keccak256("KappaAlert(address,uint8,int256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], alertTopic, "KappaAlert must NOT fire in NORMAL regime");
        }
    }

    // ─────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────

    /// @dev regime always in {0,1,2,3}; premium always reflects mark vs index
    function testFuzz_RegimeAlwaysValid(uint256 markBps) public {
        // markBps = deviation in bps (bounded to avoid circuit breaker)
        markBps = bound(markBps, 0, 70); // 0–70bps
        uint256 mark = BASE + BASE * markBps / 10000;

        adapter.recordMarkPrice(asset, mark);
        vm.warp(block.timestamp + 1);
        adapter.recordMarkPrice(asset, mark);

        (int256 k, int256 p, uint8 r) = adapter.getKappaSignal(asset);
        assertLe(r, 3, "regime must be 0-3");
        assertGe(p, -75e14, "premium cannot exceed circuit breaker magnitude (neg)");
        assertLe(p,  75e14, "premium cannot exceed circuit breaker magnitude (pos)");
        // suppress unused variable warning in fuzz
        (k);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal Chainlink-style feed mock for this test file
// ─────────────────────────────────────────────────────────────────────────────

contract MockFeed {
    int256  private _answer;
    uint8   private _decimals;
    uint256 private _updatedAt;

    constructor(uint256 /*ignored*/, uint8 dec) {
        _decimals  = dec;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 ans) external {
        _answer    = ans;
        _updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }

    function decimals() external view returns (uint8) { return _decimals; }
}
