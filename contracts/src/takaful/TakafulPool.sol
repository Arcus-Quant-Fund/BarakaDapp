// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IEverlastingOption.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title TakafulPool
 * @author Baraka Protocol
 * @notice Layer 3 — Shariah-compliant mutual insurance (Takaful) using
 *         everlasting put option pricing for fair tabarru computation.
 *
 * ══════════════════════════════════════════════════════════════════
 *  ISLAMIC FINANCE PRINCIPLE
 * ══════════════════════════════════════════════════════════════════
 * Takaful (تكافل) = "mutual guarantee". Participants donate a tabarru
 * (charitable contribution) into a shared pool. When a covered loss
 * occurs, the pool pays out from the tabarru fund. The operator manages
 * the pool under a Wakala (agency) contract, earning a fixed fee (ju'alah).
 *
 * Key Shariah compliance features:
 *   - Contributions are tabarru (donation), NOT premium (sale of risk)
 *   - No profit for operator beyond the fixed wakala fee
 *   - Surplus distributed to a designated charity / members after reserves met
 *   - No riba: the everlasting put pricing uses ι = 0 throughout
 *   - No gharar: coverage terms and floor level are explicitly defined
 *   - Pool cannot be rehypothecated or invested in interest-bearing assets
 *
 * AAOIFI Shariah Standard No. 26 — Islamic Insurance (Takaful)
 *
 * ══════════════════════════════════════════════════════════════════
 *  MATHEMATICAL BASIS  (Ackerer, Hugonnier & Jermann 2024, Prop. 6)
 * ══════════════════════════════════════════════════════════════════
 * The fair tabarru rate per unit of coverage is the everlasting put:
 *
 *   tabarruRate = Π_put(spot, floor) = [floor^{1−β₋} / (β₊−β₋)] · spot^{β₋}
 *
 * where β₋ < 0, β₊ > 1 solve ½σ²β(β−1) = κ (characteristic eq. at ι=0).
 *
 * Economic meaning: the tabarru equals the risk-neutral present value of
 * the protection payoff, discounted at the convergence rate κ (NOT at riba r).
 * Arriving at a Poisson random time θ with intensity κ, members share in
 * covering each other's losses below the floor K.
 *
 * Total tabarruGross = tabarruRate × coverageAmount / WAD
 *   tabarruRate:   dimensionless WAD ratio (Π_put output)
 *   coverageAmount: desired coverage in token raw units (e.g. USDC 1e6)
 *   tabarruGross:   result in same decimals as coverageAmount / token
 */
contract TakafulPool is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────

    uint256 public constant WAD             = 1e18;

    /// @notice Wakala agency fee: 10% of each contribution.
    ///         Deducted before tabarru is credited to the pool.
    uint256 public constant WAKALA_FEE_BPS  = 1000; // 10%

    // ─────────────────────────────────────────────────────────────
    //  Immutables
    // ─────────────────────────────────────────────────────────────

    IEverlastingOption public immutable evOption;  // Everlasting option pricer
    IOracleAdapter     public immutable oracle;    // Price oracle
    address            public immutable operator;  // Wakala agent (fee recipient)

    // ─────────────────────────────────────────────────────────────
    //  Pool configuration
    // ─────────────────────────────────────────────────────────────

    /**
     * @param asset    Reference market asset (oracle + evOption market key).
     * @param token    Payment token (e.g. USDC).
     * @param floorWad Protection floor K in WAD. Tabarru is priced to cover
     *                 losses when oracle spot falls below this level.
     * @param active   True once pool is live.
     */
    struct Pool {
        address asset;
        address token;
        uint256 floorWad;
        bool    active;
    }

    // ─────────────────────────────────────────────────────────────
    //  Member record
    // ─────────────────────────────────────────────────────────────

    struct Member {
        uint256 totalCoverage; // Sum of all coverage amounts purchased (token raw)
        uint256 totalTabarru;  // Sum of all net tabarru donated (after wakala, token raw)
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    mapping(bytes32 => Pool)                           public pools;
    mapping(bytes32 => uint256)                        public poolBalance;        // net pool holdings (token raw)
    mapping(bytes32 => mapping(address => Member))     public members;
    mapping(bytes32 => uint256)                        public totalClaimsPaid;    // cumulative claims (token raw)
    mapping(address  => bool)                          public authorisedKeepers;  // who can trigger claims

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event PoolCreated       (bytes32 indexed poolId, address asset, address token, uint256 floorWad);
    event ContributionMade  (bytes32 indexed poolId, address indexed member, uint256 coverage, uint256 tabarru, uint256 wakala);
    event ClaimPaid         (bytes32 indexed poolId, address indexed beneficiary, uint256 amount);
    event SurplusDistributed(bytes32 indexed poolId, address indexed recipient,   uint256 amount);
    event KeeperSet         (address indexed keeper, bool status);

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _evOption,
        address _oracle,
        address _operator
    ) Ownable(initialOwner) {
        require(_evOption != address(0), "TP: zero evOption");
        require(_oracle   != address(0), "TP: zero oracle");
        require(_operator != address(0), "TP: zero operator");
        evOption = IEverlastingOption(_evOption);
        oracle   = IOracleAdapter(_oracle);
        operator = _operator;
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Create a new takaful pool.
     * @param poolId   Unique identifier (e.g. keccak256("BTC-40k-floor")).
     * @param asset    Reference market (oracle key).
     * @param token    Payment token (e.g. USDC).
     * @param floorWad Protection floor in WAD (e.g. 40_000e18 = $40k for BTC).
     */
    function createPool(
        bytes32 poolId,
        address asset,
        address token,
        uint256 floorWad
    ) external onlyOwner {
        require(asset != address(0) && token != address(0), "TP: zero addr");
        require(floorWad > 0,      "TP: zero floor");
        require(!pools[poolId].active, "TP: pool exists");

        pools[poolId] = Pool({ asset: asset, token: token, floorWad: floorWad, active: true });
        emit PoolCreated(poolId, asset, token, floorWad);
    }

    function setKeeper(address keeper, bool status) external onlyOwner {
        authorisedKeepers[keeper] = status;
        emit KeeperSet(keeper, status);
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────
    //  Members
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Contribute tabarru to a pool in exchange for coverage protection.
     *
     * The required tabarru is computed from the everlasting put:
     *   tabarruGross = Π_put(oracle_spot, floor) × coverageAmount / WAD
     *
     * A 10% wakala fee is deducted immediately to the operator (ju'alah).
     * The remaining 90% is credited to the pool as the tabarru fund.
     *
     * @param poolId         Pool identifier.
     * @param coverageAmount Amount of coverage desired (token raw units, e.g. USDC).
     *                       The tabarru amount will be quoted proportionally.
     */
    function contribute(bytes32 poolId, uint256 coverageAmount)
        external
        nonReentrant
        whenNotPaused
    {
        require(coverageAmount > 0, "TP: zero coverage");
        Pool storage p = pools[poolId];
        require(p.active, "TP: pool inactive");

        // ── Compute fair tabarru from everlasting put ──────────────
        uint256 spotWad    = oracle.getIndexPrice(p.asset);
        require(spotWad > 0, "TP: zero spot");
        uint256 putRateWad = evOption.quotePut(p.asset, spotWad, p.floorWad);

        // tabarruGross = putRateWad × coverageAmount / WAD
        // putRateWad is dimensionless (WAD ratio); coverageAmount is in token raw units.
        uint256 tabarruGross = (putRateWad * coverageAmount) / WAD;
        require(tabarruGross > 0, "TP: coverage too small");

        // ── Wakala fee split ───────────────────────────────────────
        uint256 wakala  = (tabarruGross * WAKALA_FEE_BPS) / 10_000;
        uint256 tabarru = tabarruGross - wakala;

        // ── CEI: pull from member, push to operator ────────────────
        IERC20(p.token).safeTransferFrom(msg.sender, address(this), tabarruGross);
        if (wakala > 0) IERC20(p.token).safeTransfer(operator, wakala);

        // ── Record ─────────────────────────────────────────────────
        Member storage m = members[poolId][msg.sender];
        m.totalCoverage += coverageAmount;
        m.totalTabarru  += tabarru;
        poolBalance[poolId] += tabarru;

        emit ContributionMade(poolId, msg.sender, coverageAmount, tabarru, wakala);
    }

    /**
     * @notice Preview the tabarru required for `coverageAmount` at the current oracle price.
     *         Does NOT modify state.
     *
     * @return tabarruGross Total amount to send (including 10% wakala fee).
     * @return spotWad      Current oracle spot price used.
     * @return putRateWad   Π_put(spot, floor) — dimensionless WAD ratio.
     */
    function getRequiredTabarru(bytes32 poolId, uint256 coverageAmount)
        external
        view
        returns (uint256 tabarruGross, uint256 spotWad, uint256 putRateWad)
    {
        Pool storage p = pools[poolId];
        require(p.active, "TP: pool inactive");
        spotWad      = oracle.getIndexPrice(p.asset);
        putRateWad   = evOption.quotePut(p.asset, spotWad, p.floorWad);
        tabarruGross = (putRateWad * coverageAmount) / WAD;
    }

    // ─────────────────────────────────────────────────────────────
    //  Claims
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Pay a takaful claim. Callable only by authorised keepers.
     *
     *         The oracle MUST confirm spot < floor before payment is released.
     *         This is the on-chain proof that the covered event (asset falling
     *         below the floor) has occurred — eliminating the gharar objection
     *         that would arise from unverifiable credit events.
     *
     *         The payout is capped at the pool balance (mutual guarantee principle:
     *         members guarantee each other up to available funds, not beyond).
     *
     * @param poolId      Pool identifier.
     * @param beneficiary Claim recipient.
     * @param amount      Requested payout (token raw units). Capped at pool balance.
     */
    function payClaim(bytes32 poolId, address beneficiary, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        require(authorisedKeepers[msg.sender], "TP: not keeper");
        Pool storage p = pools[poolId];
        require(p.active,               "TP: pool inactive");
        require(beneficiary != address(0), "TP: zero beneficiary");
        require(amount > 0,             "TP: zero amount");

        // On-chain verification: floor must be breached
        uint256 spotWad = oracle.getIndexPrice(p.asset);
        require(spotWad < p.floorWad, "TP: floor not breached");

        uint256 avail  = poolBalance[poolId];
        uint256 payout = amount > avail ? avail : amount;
        require(payout > 0, "TP: pool empty");

        // CEI
        poolBalance[poolId]     -= payout;
        totalClaimsPaid[poolId] += payout;

        IERC20(p.token).safeTransfer(beneficiary, payout);
        emit ClaimPaid(poolId, beneficiary, payout);
    }

    // ─────────────────────────────────────────────────────────────
    //  Surplus distribution
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Distribute pool surplus to a charitable recipient.
     *         Governed by owner (Shariah multisig). Distributes only when
     *         pool balance exceeds 2× cumulative claims (prudential reserve).
     *
     *         Surplus belongs to the participants (tabarru donors), not the
     *         operator. Directing it to charity satisfies the requirement that
     *         unclaimed surplus not accumulate in the operator's hands.
     *
     * @param poolId    Pool identifier.
     * @param recipient Charity or member benefit address.
     */
    function distributeSurplus(bytes32 poolId, address recipient)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        Pool storage p = pools[poolId];
        require(p.active,                "TP: pool inactive");
        require(recipient != address(0), "TP: zero recipient");

        uint256 balance = poolBalance[poolId];
        uint256 reserve = 2 * totalClaimsPaid[poolId];
        require(balance > reserve, "TP: no surplus");

        uint256 surplus = balance - reserve;
        poolBalance[poolId] -= surplus;

        IERC20(p.token).safeTransfer(recipient, surplus);
        emit SurplusDistributed(poolId, recipient, surplus);
    }
}
