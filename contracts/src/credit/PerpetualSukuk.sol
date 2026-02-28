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
 * @title PerpetualSukuk
 * @author Baraka Protocol
 * @notice Layer 2 — On-chain sukuk (Islamic capital market instrument) with an
 *         embedded everlasting call option for asset-upside participation.
 *
 * ══════════════════════════════════════════════════════════════════
 *  ISLAMIC FINANCE PRINCIPLE
 * ══════════════════════════════════════════════════════════════════
 * Sukuk (صكوك, pl. of sakk) represent undivided ownership interests in
 * tangible assets or services — not interest-bearing debt instruments.
 *
 * This implementation uses a murabaha-secured / ijarah structure:
 *   1. ISSUANCE  — Issuer deposits par value as collateral (secured sukuk).
 *   2. SUBSCRIPTION — Investors subscribe at par; funds held by contract.
 *   3. PROFIT     — Periodic distributions computed as a profit rate on
 *                   subscribed amount (NOT interest — rate is on principal
 *                   deployment, analogous to ijarah rent).
 *   4. REDEMPTION — At maturity: principal + embedded everlasting call value.
 *
 * NO riba: the profit rate is a participation rate, not a contractual interest.
 * The embedded call is priced at ι=0 (no interest term).
 *
 * EMBEDDED CALL (Ackerer, Hugonnier & Jermann 2024, Prop. 6):
 * ─────────────────────────────────────────────────────────────
 *   callValue = Π_call(spot, par) = [par^{1−β₊} / (β₊−β₋)] · spot^{β₊}
 *
 * This gives the investor fair participation in asset appreciation above
 * the par value, evaluated at a Poisson random time with intensity κ.
 * Since ι=0, no interest term enters the pricing.
 *
 * At redemption:
 *   investorReceives = subscribed + callRateWad × subscribed / WAD
 *
 * where callRateWad = Π_call(currentSpot, parValue) — a dimensionless
 * WAD ratio expressing the call upside as a proportion of principal.
 *
 * AAOIFI Shariah Standard No. 17 — Investment Sukuk
 */
contract PerpetualSukuk is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────

    uint256 public constant WAD          = 1e18;
    uint256 public constant SECS_PER_YEAR = 365 days;

    // ─────────────────────────────────────────────────────────────
    //  Immutables
    // ─────────────────────────────────────────────────────────────

    IEverlastingOption public immutable evOption;
    IOracleAdapter     public immutable oracle;

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    uint256 private _nextId;

    /**
     * @param issuer         Sukuk originator (deposited collateral).
     * @param asset          Reference asset for embedded call (oracle + evOption market key).
     * @param token          Payment / collateral token (e.g. USDC).
     * @param parValue       Total face value in token raw units. Issuer deposits this upfront.
     * @param profitRateWad  Annual profit rate in WAD (e.g. 5e16 = 5%/year).
     * @param maturityEpoch  Unix timestamp when the sukuk matures.
     * @param issuedAt       Creation timestamp.
     * @param totalSubscribed Running total of investor subscriptions (≤ parValue).
     * @param redeemed       True when the sukuk has been fully settled.
     */
    struct SukukInfo {
        address issuer;
        address asset;
        address token;
        uint256 parValue;
        uint256 profitRateWad;
        uint256 maturityEpoch;
        uint256 issuedAt;
        uint256 totalSubscribed;
        bool    redeemed;
    }

    /**
     * @param amount       Investor's subscribed amount (token raw units).
     * @param lastProfitAt Timestamp of the investor's last profit claim.
     * @param redeemed     True once the investor has redeemed at maturity.
     */
    struct Subscription {
        uint256 amount;
        uint256 lastProfitAt;
        bool    redeemed;
    }

    mapping(uint256 => SukukInfo)                         public sukuks;
    mapping(uint256 => mapping(address => Subscription)) public subscriptions;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event SukukIssued  (uint256 indexed id, address indexed issuer, address asset, address token, uint256 par, uint256 profitRateWad, uint256 maturityEpoch);
    event Subscribed   (uint256 indexed id, address indexed investor, uint256 amount);
    event ProfitClaimed(uint256 indexed id, address indexed investor, uint256 profit);
    event Redeemed     (uint256 indexed id, address indexed investor, uint256 principal, uint256 callUpside);

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address initialOwner, address _evOption, address _oracle)
        Ownable(initialOwner)
    {
        require(_evOption != address(0), "PS: zero evOption");
        require(_oracle   != address(0), "PS: zero oracle");
        evOption = IEverlastingOption(_evOption);
        oracle   = IOracleAdapter(_oracle);
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────
    //  Issuance
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Issue a new sukuk. Issuer deposits par value as collateral.
     *
     *         The deposited parValue secures principal repayment at maturity.
     *         The embedded everlasting call gives investors upside participation
     *         in asset price movements above par at the time of redemption.
     *
     * @param asset          Reference market asset (must be configured in evOption).
     * @param token          Payment / collateral token (e.g. USDC).
     * @param parValue       Total face value (token raw units). Issuer deposits this.
     * @param profitRateWad  Annual profit rate in WAD (e.g. 5e16 = 5%).
     *                       Must be > 0 and < 100% (1e18).
     * @param maturityEpoch  Maturity unix timestamp. Must be in the future.
     * @return id            Sukuk identifier.
     */
    function issue(
        address asset,
        address token,
        uint256 parValue,
        uint256 profitRateWad,
        uint256 maturityEpoch
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        require(asset != address(0) && token != address(0), "PS: zero addr");
        require(parValue > 0,                                "PS: zero par");
        require(profitRateWad > 0 && profitRateWad < WAD,   "PS: bad rate");
        require(maturityEpoch > block.timestamp,             "PS: past maturity");

        id = _nextId++;

        sukuks[id] = SukukInfo({
            issuer:          msg.sender,
            asset:           asset,
            token:           token,
            parValue:        parValue,
            profitRateWad:   profitRateWad,
            maturityEpoch:   maturityEpoch,
            issuedAt:        block.timestamp,
            totalSubscribed: 0,
            redeemed:        false
        });

        // Pull par value as collateral from issuer (secures principal repayment)
        IERC20(token).safeTransferFrom(msg.sender, address(this), parValue);

        emit SukukIssued(id, msg.sender, asset, token, parValue, profitRateWad, maturityEpoch);
    }

    // ─────────────────────────────────────────────────────────────
    //  Subscription
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Subscribe to a sukuk (buy sukuk units at par).
     *         Investor deposits token; contract holds it until maturity.
     *
     * @param id     Sukuk identifier.
     * @param amount Amount to subscribe (token raw units). Must not exceed remaining capacity.
     */
    function subscribe(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        SukukInfo storage s = sukuks[id];
        require(!s.redeemed,                                   "PS: redeemed");
        require(block.timestamp < s.maturityEpoch,             "PS: matured");
        require(amount > 0,                                    "PS: zero amount");
        require(s.totalSubscribed + amount <= s.parValue,      "PS: over capacity");

        s.totalSubscribed += amount;

        Subscription storage sub = subscriptions[id][msg.sender];
        sub.amount       += amount;
        sub.lastProfitAt  = block.timestamp;

        IERC20(s.token).safeTransferFrom(msg.sender, address(this), amount);
        emit Subscribed(id, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    //  Profit distribution
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Claim accrued profit for an investor's subscription.
     *
     *         profit = subscribed × profitRateWad × elapsed / SECS_PER_YEAR
     *
     *         Profit is sourced from the contract's balance (issuer's collateral
     *         deposited at issuance). This mirrors ijarah: the issuer pre-deposits
     *         the total consideration; investors draw periodic profit from it.
     *
     * @param id Sukuk identifier.
     */
    function claimProfit(uint256 id) external nonReentrant whenNotPaused {
        SukukInfo storage s    = sukuks[id];
        Subscription storage sub = subscriptions[id][msg.sender];
        if (sub.amount == 0 || sub.redeemed) return; // nothing to claim

        uint256 elapsed = block.timestamp - sub.lastProfitAt;
        // profit = amount × profitRate × elapsed / year  (token raw units)
        uint256 profit = (sub.amount * s.profitRateWad * elapsed) / (WAD * SECS_PER_YEAR);
        if (profit == 0) return; // nothing accrued yet (normal for short intervals)

        sub.lastProfitAt = block.timestamp;

        IERC20(s.token).safeTransfer(msg.sender, profit);
        emit ProfitClaimed(id, msg.sender, profit);
    }

    // ─────────────────────────────────────────────────────────────
    //  Redemption at maturity
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Redeem subscribed principal + embedded everlasting call upside.
     *
     *         At maturity the investor receives:
     *           1. principal  = subscribed amount (token raw units)
     *           2. callUpside = Π_call(spot, parValue) × subscribed / WAD
     *
     *         The call upside is dimensionless (WAD ratio) × principal — it
     *         represents the fair Ackerer-Prop-6 value of asset participation
     *         above par, evaluated at the redemption spot price. No riba enters
     *         because ι=0 throughout.
     *
     *         If the contract balance is insufficient for the call upside
     *         (issuer's collateral consumed by profit distributions), the
     *         call upside is zero — investor still receives full principal.
     *
     * @param id Sukuk identifier.
     */
    function redeem(uint256 id) external nonReentrant whenNotPaused {
        SukukInfo storage s      = sukuks[id];
        Subscription storage sub = subscriptions[id][msg.sender];
        require(block.timestamp >= s.maturityEpoch, "PS: not matured");
        require(sub.amount > 0,                     "PS: not subscribed");
        require(!sub.redeemed,                      "PS: already redeemed");

        sub.redeemed = true;
        uint256 principal = sub.amount;

        // Embedded call: callRateWad = Π_call(spot, parValue)
        uint256 spotWad     = oracle.getIndexPrice(s.asset);
        uint256 callRateWad = evOption.quoteCall(s.asset, spotWad, s.parValue);
        uint256 callUpside  = (callRateWad * principal) / WAD;

        // Pay principal (always available — issuer deposited parValue at issuance)
        uint256 balance = IERC20(s.token).balanceOf(address(this));
        uint256 toPay   = principal > balance ? balance : principal;
        if (toPay > 0) IERC20(s.token).safeTransfer(msg.sender, toPay);

        // Pay call upside from remaining balance (if available)
        uint256 remaining = IERC20(s.token).balanceOf(address(this));
        uint256 actualCall = callUpside > remaining ? remaining : callUpside;
        if (actualCall > 0) IERC20(s.token).safeTransfer(msg.sender, actualCall);

        emit Redeemed(id, msg.sender, toPay, actualCall);
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Preview the embedded everlasting call value at the current oracle price.
     *
     * @param id       Sukuk identifier.
     * @param investor Investor address.
     * @return callRateWad  Π_call(spot, par) — dimensionless WAD ratio.
     * @return callUpside   callRateWad × subscribed / WAD — token raw units.
     */
    function getEmbeddedCallValue(uint256 id, address investor)
        external
        view
        returns (uint256 callRateWad, uint256 callUpside)
    {
        SukukInfo storage s    = sukuks[id];
        Subscription storage sub = subscriptions[id][investor];
        uint256 spotWad  = oracle.getIndexPrice(s.asset);
        callRateWad      = evOption.quoteCall(s.asset, spotWad, s.parValue);
        callUpside       = (callRateWad * sub.amount) / WAD;
    }

    /**
     * @notice Preview accrued profit for an investor at the current timestamp.
     *
     * @param id       Sukuk identifier.
     * @param investor Investor address.
     * @return accrued Accrued profit (token raw units).
     */
    function getAccruedProfit(uint256 id, address investor)
        external
        view
        returns (uint256 accrued)
    {
        SukukInfo storage s      = sukuks[id];
        Subscription storage sub = subscriptions[id][investor];
        if (sub.amount == 0 || sub.redeemed) return 0;
        uint256 elapsed = block.timestamp - sub.lastProfitAt;
        accrued = (sub.amount * s.profitRateWad * elapsed) / (WAD * SECS_PER_YEAR);
    }

    /// @notice Returns the next sukuk ID (= current count of issued sukuks).
    function nextId() external view returns (uint256) { return _nextId; }
}
