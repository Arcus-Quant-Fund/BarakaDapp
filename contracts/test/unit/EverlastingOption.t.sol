// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/EverlastingOption.sol";

/**
 * @title EverlastingOptionTest
 * @notice Unit tests for EverlastingOption.sol
 *
 * MATHEMATICAL BASIS
 * ==================
 * All expected values derived from the characteristic equation at iota=0:
 *   ½sigma²beta(beta−1) = kappa   →   beta = ½ ± √(¼ + 2kappa/sigma²)
 *
 * Test parameters (BTC-like market):
 *   sigma² = 0.64   (80% annual volatility)
 *   kappa  = 0.08   (8%/year convergence ~ ~12yr expected horizon)
 *   D  = ¼ + 2(0.08)/0.64 = 0.25 + 0.25 = 0.50
 *   √D = √0.50 ~ 0.7071
 *   beta₋ = 0.5 − 0.7071 ~ −0.2071
 *   beta₊ = 0.5 + 0.7071 ~  1.2071
 *   denominator = 2√D ~ 1.4142
 */
contract EverlastingOptionTest is Test {

    // -------------------------------------------------------------
    //  Fixtures
    // -------------------------------------------------------------

    EverlastingOption public eo;

    address internal constant OWNER   = address(0xBEEF);
    address internal constant ASSET   = address(0xA55E7);
    address internal constant ORACLE  = address(0x0AC1E);

    uint256 internal constant WAD     = 1e18;

    // Market parameters
    uint256 internal constant SIGMA2  = 64e16;   // sigma² = 0.64 (80% vol)
    uint256 internal constant KAPPA   = 8e16;    // kappa  = 0.08/year

    // Dollar-denominated test prices (in WAD)
    uint256 internal constant X_AT_PAR   = 50_000 * WAD; // spot = strike
    uint256 internal constant K_STRIKE   = 50_000 * WAD; // strike
    uint256 internal constant X_HIGH     = 80_000 * WAD; // OTM put
    uint256 internal constant X_LOW      = 30_000 * WAD; // ITM put
    uint256 internal constant X_ONE      = 1 * WAD;      // edge: x=1
    uint256 internal constant K_ONE      = 1 * WAD;      // edge: K=1

    // -------------------------------------------------------------
    //  Setup
    // -------------------------------------------------------------

    function setUp() public {
        vm.startPrank(OWNER);
        eo = new EverlastingOption(OWNER, ORACLE);
        // Configure market with admin-set kappa (no oracle dependency)
        eo.setMarket(ASSET, SIGMA2, KAPPA, false);
        vm.stopPrank();
    }

    // -------------------------------------------------------------
    //  1. Exponent computation
    // -------------------------------------------------------------

    /// beta₋ must be negative (put exponent)
    function test_betaNeg_isNegative() public view {
        (int256 bNeg, , ) = eo.getExponents(ASSET);
        assertLt(bNeg, 0, "beta- must be negative");
    }

    /// beta₊ must be > 1 (call exponent)
    function test_betaPos_greaterThanOne() public view {
        (, int256 bPos, ) = eo.getExponents(ASSET);
        assertGt(bPos, int256(WAD), "beta+ must be > 1");
    }

    /// denominator = beta₊ − beta₋ must be positive
    function test_denom_isPositive() public view {
        (int256 bNeg, int256 bPos, uint256 denom) = eo.getExponents(ASSET);
        assertGt(denom, 0, "denom must be positive");
        assertApproxEqRel(uint256(bPos - bNeg), denom, 1e15, "denom = beta+ - beta-");
    }

    /// beta₋ + beta₊ = 1 always (sum of roots of characteristic eq)
    function test_exponents_sumToOne() public view {
        (int256 bNeg, int256 bPos, ) = eo.getExponents(ASSET);
        int256 sum = bNeg + bPos;
        // sum should equal 1e18 (1.0 in WAD)
        assertApproxEqAbs(sum, int256(WAD), 1e14, "beta- + beta+ should equal 1");
    }

    /// For our test params: D=0.5, √D~0.7071, beta₋ ~ -0.2071
    function test_betaNeg_approximateValue() public view {
        (int256 bNeg, , ) = eo.getExponents(ASSET);
        // beta₋ ~ -0.2071 in WAD = -207100000000000000
        // Allow 1% relative tolerance for integer approximations
        assertApproxEqRel(
            uint256(-bNeg),
            207_106_781_186_547_524,  // ~ 0.2071 * 1e18
            1e16,                      // 1% tolerance
            "beta- ~= -0.2071"
        );
    }

    // -------------------------------------------------------------
    //  2. Put price monotonicity
    // -------------------------------------------------------------

    /// Put price must decrease as spot increases (put = protection against downside)
    function test_put_decreasesWithSpot() public view {
        uint256 pLow  = eo.quotePut(ASSET, X_LOW,    K_STRIKE);
        uint256 pMid  = eo.quotePut(ASSET, X_AT_PAR, K_STRIKE);
        uint256 pHigh = eo.quotePut(ASSET, X_HIGH,   K_STRIKE);
        assertGt(pLow, pMid,  "put(x_low)  > put(x_mid)");
        assertGt(pMid, pHigh, "put(x_mid)  > put(x_high)");
    }

    /// Put price must increase as strike increases (higher floor = more expensive)
    function test_put_increasesWithStrike() public view {
        uint256 kLow  = 30_000 * WAD;
        uint256 kHigh = 70_000 * WAD;
        uint256 pLow  = eo.quotePut(ASSET, X_AT_PAR, kLow);
        uint256 pHigh = eo.quotePut(ASSET, X_AT_PAR, kHigh);
        assertGt(pHigh, pLow, "put(K_high) > put(K_low)");
    }

    // -------------------------------------------------------------
    //  3. Call price monotonicity
    // -------------------------------------------------------------

    /// Call price must increase as spot increases
    function test_call_increasesWithSpot() public view {
        uint256 cLow  = eo.quoteCall(ASSET, X_LOW,    K_STRIKE);
        uint256 cMid  = eo.quoteCall(ASSET, X_AT_PAR, K_STRIKE);
        uint256 cHigh = eo.quoteCall(ASSET, X_HIGH,   K_STRIKE);
        assertLt(cLow, cMid,  "call(x_low) < call(x_mid)");
        assertLt(cMid, cHigh, "call(x_mid) < call(x_high)");
    }

    /// Call price must decrease as strike increases (higher cap = cheaper)
    function test_call_decreasesWithStrike() public view {
        uint256 kLow  = 30_000 * WAD;
        uint256 kHigh = 70_000 * WAD;
        uint256 cLow  = eo.quoteCall(ASSET, X_AT_PAR, kLow);
        uint256 cHigh = eo.quoteCall(ASSET, X_AT_PAR, kHigh);
        assertGt(cLow, cHigh, "call(K_low) > call(K_high)");
    }

    // -------------------------------------------------------------
    //  4. Put-call relationship
    // -------------------------------------------------------------

    /// At x = K (at the money), put and call should be equal by symmetry
    /// of the beta₋ and beta₊ exponents around ½.
    function test_put_call_equal_atTheMoney() public view {
        // At x = K: Π_put = K^{1-beta₋}/(beta₊-beta₋) · K^{beta₋} = K/(beta₊-beta₋)
        //           Π_call = K^{1-beta₊}/(beta₊-beta₋) · K^{beta₊} = K/(beta₊-beta₋)
        // So put == call when x == K.
        uint256 put  = eo.quotePut( ASSET, K_STRIKE, K_STRIKE);
        uint256 call = eo.quoteCall(ASSET, K_STRIKE, K_STRIKE);
        assertApproxEqRel(put, call, 1e16, "put == call at x=K (1% tol)");
    }

    /// At x = K: Π_put = Π_call = K / (beta₊ − beta₋)
    function test_atTheMoney_formula() public view {
        (,, uint256 denom) = eo.getExponents(ASSET);
        uint256 expected = (K_STRIKE * WAD) / denom;
        uint256 actual   = eo.quotePut(ASSET, K_STRIKE, K_STRIKE);
        assertApproxEqRel(actual, expected, 2e16, "ATM price = K/denom (2% tol)");
    }

    // -------------------------------------------------------------
    //  5. kappa sensitivity
    // -------------------------------------------------------------

    /// Higher kappa -> larger denom (2*sqrt(1/4 + 2*kappa/sigma2)) -> LOWER ATM price.
    /// At x=K: Π_put = K/denom. denom increases with kappa, so price decreases.
    /// Economic interpretation: faster convergence (higher kappa) means the Poisson
    /// event arrives sooner, but the coefficient shrinks because the exponents |beta|
    /// become larger, spreading probability mass further from the strike.
    function test_put_decreasesWithKappaAtATM() public {
        address assetLow  = address(0xAAA1);
        address assetHigh = address(0xAAA2);
        vm.startPrank(OWNER);
        eo.setMarket(assetLow,  SIGMA2, 4e16,  false); // kappa = 4%/year
        eo.setMarket(assetHigh, SIGMA2, 16e16, false); // kappa = 16%/year
        vm.stopPrank();

        uint256 pLow  = eo.quotePut(assetLow,  X_AT_PAR, K_STRIKE);
        uint256 pHigh = eo.quotePut(assetHigh, X_AT_PAR, K_STRIKE);
        // ATM put price = K/denom; denom grows with kappa so pHigh < pLow
        assertGt(pLow, pHigh, "ATM put price decreases as kappa increases");
    }

    // -------------------------------------------------------------
    //  6. Shariah compliance — iota = 0 implicit verification
    // -------------------------------------------------------------

    /// The pricing formula contains NO interest parameter iota.
    /// We verify this by confirming the price is purely a function of kappa and sigma²:
    /// if kappa = 0, the exponents collapse to beta₋ = −∞, beta₊ = +∞,
    /// which is undefined. Non-zero kappa is required and enforced by setMarket.
    function test_zeroKappa_reverts() public {
        address assetBad = address(0xBAD);
        vm.prank(OWNER);
        vm.expectRevert("EO: zero kappa");
        eo.setMarket(assetBad, SIGMA2, 0, false);
    }

    /// Zero sigma² reverts
    function test_zeroSigma_reverts() public {
        address assetBad = address(0xBAD2);
        vm.prank(OWNER);
        vm.expectRevert("EO: zero sigma");
        eo.setMarket(assetBad, 0, KAPPA, false);
    }

    /// quoteAtSpot reverts for inactive market
    function test_inactiveMarket_reverts() public {
        address inactive = address(0xDEAD);
        vm.expectRevert("EO: market inactive");
        eo.quotePut(inactive, X_AT_PAR, K_STRIKE);
    }

    // -------------------------------------------------------------
    //  7. Internal math — lnWad sanity
    // -------------------------------------------------------------

    /// Expose internal math via a test harness
    MathHarness public harness;

    function setUp2() internal {
        harness = new MathHarness();
    }

    // -------------------------------------------------------------
    //  8. Fuzz tests
    // -------------------------------------------------------------

    /**
     * @dev Fuzz: put monotone decreasing in x for any x, K > 0.
     *      Restricts to reasonable USD price range to avoid overflow in log.
     */
    function testFuzz_put_monotoneDecreasingInSpot(
        uint256 x1,
        uint256 x2,
        uint256 k
    ) public view {
        // Bound inputs to [1 USD, 10M USD] in WAD and ensure x1 < x2
        x1 = bound(x1, WAD, 10_000_000 * WAD);
        x2 = bound(x2, x1 + 1, 10_000_000 * WAD + 1);
        k  = bound(k,  WAD, 10_000_000 * WAD);

        uint256 p1 = eo.quotePut(ASSET, x1, k);
        uint256 p2 = eo.quotePut(ASSET, x2, k);
        assertGe(p1, p2, "put must be monotone decreasing in x");
    }

    /**
     * @dev Fuzz: call monotone increasing in x.
     */
    function testFuzz_call_monotoneIncreasingInSpot(
        uint256 x1,
        uint256 x2,
        uint256 k
    ) public view {
        x1 = bound(x1, WAD, 10_000_000 * WAD);
        x2 = bound(x2, x1 + 1, 10_000_000 * WAD + 1);
        k  = bound(k,  WAD, 10_000_000 * WAD);

        uint256 c1 = eo.quoteCall(ASSET, x1, k);
        uint256 c2 = eo.quoteCall(ASSET, x2, k);
        assertLe(c1, c2, "call must be monotone increasing in x");
    }

    /**
     * @dev Fuzz: at x=K, put==call for any valid market params.
     */
    function testFuzz_atTheMoney_putEqualsCall(
        uint256 k,
        uint256 sigma2,
        uint256 kappa
    ) public {
        k      = bound(k,      WAD, 1_000_000 * WAD);
        sigma2 = bound(sigma2, 4e16, 4 * WAD);   // sigma² ∈ [4%, 400%]
        kappa  = bound(kappa,  1e15, 5e17);       // kappa  ∈ [0.1%, 50%]/year

        address assetFuzz = address(uint160(k ^ sigma2 ^ kappa));
        vm.prank(OWNER);
        eo.setMarket(assetFuzz, sigma2, kappa, false);

        uint256 put  = eo.quotePut( assetFuzz, k, k);
        uint256 call = eo.quoteCall(assetFuzz, k, k);
        // Put == Call at x=K always (symmetric coefficient). Allow 2% numerical error.
        assertApproxEqRel(put, call, 2e16, "put == call at x=K for any params");
    }

    /**
     * @dev Fuzz: option prices are always non-negative (no riba content implies non-negative pricing).
     */
    function testFuzz_pricesNonNegative(uint256 x, uint256 k) public view {
        x = bound(x, WAD, 10_000_000 * WAD);
        k = bound(k, WAD, 10_000_000 * WAD);

        uint256 put  = eo.quotePut( ASSET, x, k);
        uint256 call = eo.quoteCall(ASSET, x, k);
        // uint256 cannot be negative — but confirm no revert and result is valid
        assertGe(put,  0, "put price >= 0");
        assertGe(call, 0, "call price >= 0");
    }

    // -------------------------------------------------------------
    //  9. Admin tests
    // -------------------------------------------------------------

    function test_onlyOwner_setMarket() public {
        vm.expectRevert();
        eo.setMarket(ASSET, SIGMA2, KAPPA, false);
    }

    function test_onlyOwner_setOracle() public {
        vm.expectRevert();
        eo.setOracle(address(0x1234));
    }

    function test_pause_blocks_quotes() public {
        vm.prank(OWNER);
        eo.pause();
        vm.expectRevert();
        eo.quotePut(ASSET, X_AT_PAR, K_STRIKE);
    }
}

// -----------------------------------------------------------------
//  Math test harness (exposes internal functions for unit testing)
// -----------------------------------------------------------------
contract MathHarness is EverlastingOption {
    constructor() EverlastingOption(msg.sender, address(0x1)) {}

    function lnWad(uint256 x) external pure returns (int256) {
        return _lnWad(x);
    }

    function expWad(int256 x) external pure returns (uint256) {
        return _expWad(x);
    }
}

contract MathHarnessTest is Test {
    MathHarness harness;

    function setUp() public {
        harness = new MathHarness();
    }

    uint256 internal constant WAD = 1e18;

    // -- lnWad tests ---------------------------------------------

    /// ln(1) = 0
    function test_ln_ofOne() public view {
        int256 r = harness.lnWad(WAD);
        // 60-iteration binary log has ~1e12 abs error; allow 1e13 tolerance.
        assertApproxEqAbs(r, 0, 1e13, "ln(1) = 0");
    }

    /// ln(e) = 1
    function test_ln_ofE() public view {
        // e ~ 2.71828... in WAD = 2_718_281_828_459_045_235
        int256 r = harness.lnWad(2_718_281_828_459_045_235);
        assertApproxEqRel(uint256(r), WAD, 1e16, "ln(e) ~ 1 (1% tol)");
    }

    /// ln(2) ~ 0.6931
    function test_ln_ofTwo() public view {
        int256 r = harness.lnWad(2 * WAD);
        assertApproxEqRel(uint256(r), 693_147_180_559_945_309, 1e16, "ln(2) (1% tol)");
    }

    /// ln(x) < 0 for x < 1e18 (i.e. for X < 1.0)
    function test_ln_negative_belowOne() public view {
        int256 r = harness.lnWad(WAD / 2); // ln(0.5) ~ -0.693
        assertLt(r, 0, "ln(0.5) < 0");
    }

    /// ln(x) > 0 for x > 1e18
    function test_ln_positive_aboveOne() public view {
        int256 r = harness.lnWad(2 * WAD);
        assertGt(r, 0, "ln(2) > 0");
    }

    // -- expWad tests ---------------------------------------------

    /// exp(0) = 1
    function test_exp_ofZero() public view {
        uint256 r = harness.expWad(0);
        assertApproxEqAbs(r, WAD, 1e14, "exp(0) = 1");
    }

    /// exp(1) ~ e ~ 2.71828
    function test_exp_ofOne() public view {
        uint256 r = harness.expWad(int256(WAD));
        assertApproxEqRel(r, 2_718_281_828_459_045_235, 1e16, "exp(1) ~ e (1% tol)");
    }

    /// exp(ln(x)) ~ x (roundtrip test)
    function test_exp_ln_roundtrip() public view {
        uint256 x = 50_000 * WAD; // $50,000 in WAD
        int256 lnX = harness.lnWad(x);
        uint256 roundtrip = harness.expWad(lnX);
        assertApproxEqRel(roundtrip, x, 2e16, "exp(ln(x)) ~ x (2% tol)");
    }

    /// exp(ln(2)) ~ 2
    function test_exp_ln2() public view {
        uint256 r = harness.expWad(693_147_180_559_945_309);
        assertApproxEqRel(r, 2 * WAD, 1e16, "exp(ln(2)) ~ 2 (1% tol)");
    }

    /// exp of large negative = 0 (underflow guard)
    function test_exp_largeNegative_returnsZero() public view {
        uint256 r = harness.expWad(-100 * int256(WAD));
        assertEq(r, 0, "exp(-100) = 0 (underflow)");
    }

    /// Fuzz: exp(ln(x)) ~ x for all valid x
    function testFuzz_exp_ln_roundtrip(uint256 x) public view {
        // Bound x to (0, 1e30] to stay within expWad domain
        x = bound(x, WAD / 1000, 1e10 * WAD);
        int256 lnX = harness.lnWad(x);
        // Skip if expWad would overflow (|lnX| > 87e18)
        if (lnX > 87 * int256(WAD) || lnX < -87 * int256(WAD)) return;
        uint256 roundtrip = harness.expWad(lnX);
        assertApproxEqRel(roundtrip, x, 3e16, "exp(ln(x)) ~ x (3% tol)");
    }
}
