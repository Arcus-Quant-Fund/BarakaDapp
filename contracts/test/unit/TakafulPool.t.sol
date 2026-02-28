// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/takaful/TakafulPool.sol";
import "../../src/core/EverlastingOption.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracle.sol";

/**
 * @title TakafulPoolTest
 * @notice Unit tests for TakafulPool (Layer 3 mutual insurance).
 *
 * Pricing economics (WAD arithmetic):
 * ─────────────────────────────────────
 * quotePut(spot=50_000e18, floor=40_000e18) ≈ 27_018e18  (absolute put price in WAD)
 *
 * tabarruGross = quotePut × coverageAmount / WAD
 *
 * With 18-decimal tokens and coverageAmount = 1e18 (1 "unit"):
 *   tabarruGross ≈ 27_018e18 × 1e18 / 1e18 = 27_018e18 tokens
 *   → Mint MEMBER 1_000_000e18 so tests have enough balance.
 *
 * With tiny coverage (1e6 = 0.000001 units):
 *   tabarruGross ≈ 27_018e18 × 1e6 / 1e18 = 27_018e6 ≈ 27k tokens at 18-dec.
 *   → More practical for individual test cases.
 */
contract TakafulPoolTest is Test {

    TakafulPool       pool;
    EverlastingOption eo;
    MockOracle        mockOracle;
    MockERC20         token18;  // 18-decimal token

    address constant OWNER    = address(0xBEEF);
    address constant MEMBER   = address(0xA001);
    address constant MEMBER2  = address(0xA002);
    address constant KEEPER   = address(0xBEAD);
    address constant OPERATOR = address(0xFEE5);
    address constant CHARITY  = address(0xC0DE);

    address constant ASSET    = address(0xBBCC);

    // BTC-like: sigma²=0.64 (80% vol), kappa=0.08/year
    uint256 constant SIGMA2    = 64e16;
    uint256 constant KAPPA     = 8e16;
    uint256 constant SPOT_WAD  = 50_000e18;  // $50k BTC
    uint256 constant FLOOR_WAD = 40_000e18;  // $40k floor

    bytes32 constant POOL_ID  = keccak256("BTC-40k-2026");
    uint256 constant WAD      = 1e18;

    // Practical coverage unit: 1e12 (0.000001 "asset units" at 18-dec)
    // tabarruGross ≈ 27018e18 × 1e12 / 1e18 = 27_018e12 ≈ 27k tokens (18-dec)
    uint256 constant COV_UNIT = 1e12;

    function setUp() public {
        vm.startPrank(OWNER);

        mockOracle = new MockOracle();
        mockOracle.setIndexPrice(ASSET, SPOT_WAD);

        eo = new EverlastingOption(OWNER, address(mockOracle));
        eo.setMarket(ASSET, SIGMA2, KAPPA, false);

        token18 = new MockERC20("Pool Token", "PTKN", 18);

        pool = new TakafulPool(OWNER, address(eo), address(mockOracle), OPERATOR);
        pool.createPool(POOL_ID, ASSET, address(token18), FLOOR_WAD);
        pool.setKeeper(KEEPER, true);

        vm.stopPrank();

        // Mint generous balances (1M tokens each)
        token18.mint(MEMBER,  1_000_000e18);
        token18.mint(MEMBER2, 1_000_000e18);
        vm.prank(MEMBER);  token18.approve(address(pool), type(uint256).max);
        vm.prank(MEMBER2); token18.approve(address(pool), type(uint256).max);
    }

    // ─── 1. Pool creation ──────────────────────────────────────────

    function test_poolCreated_isActive() public view {
        (, , uint256 floorWad, bool active) = pool.pools(POOL_ID);
        assertTrue(active,              "pool must be active");
        assertEq(floorWad, FLOOR_WAD,  "floor mismatch");
    }

    function test_createPool_duplicateReverts() public {
        vm.prank(OWNER);
        vm.expectRevert("TP: pool exists");
        pool.createPool(POOL_ID, ASSET, address(token18), FLOOR_WAD);
    }

    function test_onlyOwner_createPool() public {
        vm.expectRevert();
        pool.createPool(keccak256("other"), ASSET, address(token18), FLOOR_WAD);
    }

    // ─── 2. Contribution mechanics ────────────────────────────────

    function test_contribute_reducesBalanceAndFillsPool() public {
        uint256 coverage = COV_UNIT;
        (uint256 tGross,,) = pool.getRequiredTabarru(POOL_ID, coverage);
        assertGt(tGross, 0, "tabarru must be positive");

        uint256 wakala   = (tGross * 1000) / 10_000; // 10%
        uint256 tabarru  = tGross - wakala;

        uint256 memberBefore   = token18.balanceOf(MEMBER);
        uint256 operatorBefore = token18.balanceOf(OPERATOR);

        vm.prank(MEMBER);
        pool.contribute(POOL_ID, coverage);

        assertApproxEqAbs(token18.balanceOf(MEMBER), memberBefore - tGross, 1, "member pays gross");
        assertApproxEqAbs(token18.balanceOf(OPERATOR), operatorBefore + wakala, 1, "operator gets wakala");
        assertEq(pool.poolBalance(POOL_ID), tabarru, "net tabarru in pool");

        (uint256 totalCov, uint256 totalTab) = pool.members(POOL_ID, MEMBER);
        assertEq(totalCov, coverage, "member coverage recorded");
        assertEq(totalTab, tabarru,  "member tabarru recorded");
    }

    function test_contribute_zeroReverts() public {
        vm.prank(MEMBER);
        vm.expectRevert("TP: zero coverage");
        pool.contribute(POOL_ID, 0);
    }

    function test_contribute_inactivePoolReverts() public {
        bytes32 fakeId = keccak256("fake");
        vm.prank(MEMBER);
        vm.expectRevert("TP: pool inactive");
        pool.contribute(fakeId, COV_UNIT);
    }

    // ─── 3. Tabarru pricing — increases as spot falls toward floor ─

    function test_tabarruRate_increasesAsSpotFalls() public view {
        // High spot: OTM put → smaller absolute put price
        uint256 putHigh = eo.quotePut(ASSET, 70_000e18, FLOOR_WAD);
        // Spot closer to floor: larger put price (more protection probability)
        uint256 putLow  = eo.quotePut(ASSET, 42_000e18, FLOOR_WAD);
        assertGt(putLow, putHigh, "put increases as spot falls toward floor");
    }

    function test_getRequiredTabarru_nonZero() public view {
        (uint256 gross, uint256 spotWad_, uint256 putRate_) = pool.getRequiredTabarru(POOL_ID, COV_UNIT);
        assertGt(gross,    0, "tabarru > 0");
        assertGt(spotWad_, 0, "spot > 0");
        assertGt(putRate_, 0, "put rate > 0");
    }

    // ─── 4. Claim payout ──────────────────────────────────────────

    function test_payClaim_whenFloorBreached() public {
        vm.prank(MEMBER);
        pool.contribute(POOL_ID, COV_UNIT * 100);

        uint256 poolBal = pool.poolBalance(POOL_ID);
        assertGt(poolBal, 0, "pool must have balance");

        // Drop spot below floor
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 39_000e18);

        uint256 claimAmt     = poolBal / 2;
        uint256 charityBefore = token18.balanceOf(CHARITY);

        vm.prank(KEEPER);
        pool.payClaim(POOL_ID, CHARITY, claimAmt);

        assertEq(token18.balanceOf(CHARITY), charityBefore + claimAmt, "charity paid");
        assertEq(pool.poolBalance(POOL_ID), poolBal - claimAmt,        "pool balance reduced");
        assertEq(pool.totalClaimsPaid(POOL_ID), claimAmt,              "claims tracked");
    }

    function test_payClaim_requiresFloorBreach() public {
        vm.prank(MEMBER);
        pool.contribute(POOL_ID, COV_UNIT);

        // Spot is above floor ($50k > $40k) — no breach
        vm.prank(KEEPER);
        vm.expectRevert("TP: floor not breached");
        pool.payClaim(POOL_ID, CHARITY, 1e12);
    }

    function test_payClaim_requiresKeeper() public {
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 39_000e18);

        vm.prank(MEMBER); // not a keeper
        vm.expectRevert("TP: not keeper");
        pool.payClaim(POOL_ID, CHARITY, 1e12);
    }

    function test_payClaim_capsAtBalance() public {
        vm.prank(MEMBER);
        pool.contribute(POOL_ID, COV_UNIT);

        uint256 poolBal = pool.poolBalance(POOL_ID);
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 39_000e18);

        // Request 10× more than pool holds
        vm.prank(KEEPER);
        pool.payClaim(POOL_ID, CHARITY, poolBal * 10);

        assertEq(pool.poolBalance(POOL_ID), 0,      "pool drained");
        assertEq(token18.balanceOf(CHARITY), poolBal, "charity got exactly poolBal");
    }

    // ─── 5. Surplus distribution ──────────────────────────────────

    function test_distributeSurplus_whenNoClaims() public {
        // Contribute; no claims → totalClaimsPaid=0 → reserve=0 → all is surplus
        vm.prank(MEMBER);
        pool.contribute(POOL_ID, COV_UNIT * 100);
        vm.prank(MEMBER2);
        pool.contribute(POOL_ID, COV_UNIT * 100);

        uint256 charityBefore = token18.balanceOf(CHARITY);

        vm.prank(OWNER);
        pool.distributeSurplus(POOL_ID, CHARITY);

        assertGt(token18.balanceOf(CHARITY), charityBefore, "charity received surplus");
        assertEq(pool.poolBalance(POOL_ID), 0,              "pool emptied to charity");
    }

    function test_distributeSurplus_noSurplusReverts() public {
        // Contribute a small amount, then pay a large claim
        vm.prank(MEMBER);
        pool.contribute(POOL_ID, COV_UNIT);
        uint256 poolBal = pool.poolBalance(POOL_ID);

        // Trigger claim (all of pool)
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 39_000e18);
        vm.prank(KEEPER);
        pool.payClaim(POOL_ID, CHARITY, poolBal);

        // Restore price above floor and contribute small amount back
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, SPOT_WAD);
        vm.prank(MEMBER2);
        pool.contribute(POOL_ID, COV_UNIT);

        // balance < 2 × totalClaimsPaid → no surplus
        vm.prank(OWNER);
        vm.expectRevert("TP: no surplus");
        pool.distributeSurplus(POOL_ID, CHARITY);
    }

    // ─── 6. Pause ─────────────────────────────────────────────────

    function test_pause_blocksContribute() public {
        vm.prank(OWNER); pool.pause();
        vm.prank(MEMBER);
        vm.expectRevert();
        pool.contribute(POOL_ID, COV_UNIT);
    }

    // ─── 7. Wakala split is exactly 10% ───────────────────────────

    function testFuzz_wakala_isTenPercent(uint256 coverage) public {
        coverage = bound(coverage, 1e6, 1e16); // small enough to stay within budget

        (uint256 gross,,) = pool.getRequiredTabarru(POOL_ID, coverage);
        if (gross == 0) return; // skip dust

        uint256 expectedWakala = (gross * 1000) / 10_000;
        uint256 expectedNet    = gross - expectedWakala;

        uint256 operatorBefore = token18.balanceOf(OPERATOR);

        vm.prank(MEMBER);
        pool.contribute(POOL_ID, coverage);

        assertApproxEqAbs(
            token18.balanceOf(OPERATOR) - operatorBefore,
            expectedWakala,
            1,
            "wakala = 10% of gross"
        );
        assertApproxEqAbs(pool.poolBalance(POOL_ID), expectedNet, 1, "net = 90%");
    }
}
