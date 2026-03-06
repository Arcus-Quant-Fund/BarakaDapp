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
 * @title iCDS
 * @author Baraka Protocol
 * @notice Layer 4 — Islamic Credit Default Swap: riba-free, gharar-reduced
 *         credit protection using everlasting put pricing.
 *
 * ══════════════════════════════════════════════════════════════════
 *  ISLAMIC FINANCE PRINCIPLE
 * ══════════════════════════════════════════════════════════════════
 * Conventional CDS are deemed impermissible under classical fiqh because:
 *   (a) maysir (gambling): seller bets on default without underlying exposure
 *   (b) gharar (uncertainty): credit event definition may be ambiguous
 *   (c) riba: fixed premium on notional resembles interest payment
 *
 * The iCDS addresses each objection:
 *   (a) Seller must deposit full notional as collateral (not a naked bet).
 *       Buyer must hold the reference exposure off-chain (Shariah attestation).
 *   (b) Credit event = verifiable on-chain oracle: spot ≤ recoveryFloor.
 *       The recoveryFloor is pre-agreed and transparent — no ambiguous committees.
 *   (c) Premium = Π_put(spot, recoveryFloor) × notional / WAD (Ackerer Prop. 6)
 *       This is the risk-neutral expected loss under ι=0, NOT a fixed rate.
 *       Premium adjusts dynamically with market conditions — no riba element.
 *
 * Structure (Takaful analogy):
 *   - Seller plays the role of the takaful pool (absorbs losses).
 *   - Buyer plays the role of the tabarru contributor + beneficiary.
 *   - Premium = fair put price replaces conventional fixed spread.
 *
 * Reference: Ahmed, Bhuyan & Islam (2026), "Random Stopping Time as Credit
 * Event: A Riba-Free Credit Pricing Framework", Paper 2.
 *
 * ══════════════════════════════════════════════════════════════════
 *  MATHEMATICAL BASIS  (Ackerer, Hugonnier & Jermann 2024, Prop. 6)
 * ══════════════════════════════════════════════════════════════════
 * The credit event is modelled as a Poisson stopping time θ with intensity κ.
 * This is exactly the "random stopping time ≡ credit event" equivalence from
 * Paper 2: the hazard rate λ maps to κ, and the stopping time τ maps to θ.
 *
 * Quarterly premium per period:
 *   premium = Π_put(spot, recoveryFloor) × notional / WAD
 *
 * where recoveryFloor = recoveryRate × oracle_spot_at_open.
 *
 * ══════════════════════════════════════════════════════════════════
 *  CONTRACT FLOW
 * ══════════════════════════════════════════════════════════════════
 *   1. seller: openProtection(...)     → deposits notional as collateral
 *   2. buyer:  acceptProtection(id)    → accepts terms; pays first premium
 *   3. buyer:  payPremium(id)          → pays quarterly premium (dynamic)
 *   4. keeper: triggerCreditEvent(id)  → oracle confirms spot ≤ recoveryFloor
 *   5. buyer:  settle(id)             → receives notional × (1 − recovery)
 *   6. seller: expire(id)             → no default at tenor end → reclaims collateral
 */
contract iCDS is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────

    uint256 public constant WAD            = 1e18;
    uint256 public constant SECS_PER_YEAR  = 365 days;

    /// @notice Premium payment interval: quarterly (90 days).
    uint256 public constant PREMIUM_PERIOD = 90 days;

    /**
     * @notice After triggerCreditEvent, the buyer has SETTLEMENT_WINDOW to call settle().
     *         If the window passes without settlement, anyone may call expireTrigger()
     *         to release the seller's collateral.
     *
     *         Rationale: without a deadline the seller's notional can be locked
     *         indefinitely — a griefing vector where the buyer waits for price recovery
     *         then settles a stale trigger. 7 days is generous for any buyer to act.
     */
    uint256 public constant SETTLEMENT_WINDOW = 7 days;

    // ─────────────────────────────────────────────────────────────
    //  Immutables
    // ─────────────────────────────────────────────────────────────

    IEverlastingOption public immutable evOption;
    IOracleAdapter     public immutable oracle;

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    uint256 private _nextId;

    mapping(address => bool) public authorisedKeepers;

    enum Status { Open, Active, Triggered, Settled, Expired }

    /**
     * @param seller            Protection seller (deposited notional as collateral).
     * @param buyer             Protection buyer (accepted and pays premiums).
     * @param refAsset          Reference market asset (oracle + evOption key).
     * @param token             Collateral / premium token.
     * @param notional          Total collateral (= max payout) in token raw units.
     * @param recoveryRateWad   Expected recovery rate in WAD (e.g. 40e16 = 40%).
     * @param recoveryFloorWad  Strike for put pricing: recoveryRate × spot_at_open (WAD).
     * @param tenorEnd          Unix timestamp when protection expires.
     * @param lastPremiumAt     Timestamp of last premium payment (or acceptance).
     * @param premiumsCollected Total premiums paid to seller so far.
     * @param triggeredAt       Timestamp when triggerCreditEvent was called (0 if never).
     *                          Buyer must call settle() within triggeredAt + SETTLEMENT_WINDOW.
     * @param status            Current lifecycle status.
     */
    struct Protection {
        address seller;
        address buyer;
        address refAsset;
        address token;
        uint256 notional;
        uint256 recoveryRateWad;
        uint256 recoveryFloorWad;
        uint256 tenorEnd;
        uint256 lastPremiumAt;
        uint256 premiumsCollected;
        uint256 triggeredAt;
        Status  status;
    }

    mapping(uint256 => Protection) public protections;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event ProtectionOpened    (uint256 indexed id, address indexed seller, address refAsset, address token, uint256 notional, uint256 tenorEnd);
    event ProtectionAccepted  (uint256 indexed id, address indexed buyer);
    event PremiumPaid         (uint256 indexed id, address indexed buyer,  uint256 amount);
    event CreditEventTriggered(uint256 indexed id, address indexed keeper, uint256 spotWad, uint256 floorWad);
    event Settled             (uint256 indexed id, address indexed buyer,  uint256 payout, uint256 sellerReturn);
    event Expired             (uint256 indexed id, address indexed seller, uint256 collateralReturned);
    /// @notice Emitted when a triggered credit event expires unresolved (buyer did not settle in time).
    event TriggerExpired      (uint256 indexed id, address indexed caller, address indexed seller, uint256 collateralReturned);
    event KeeperSet           (address indexed keeper, bool status);

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address initialOwner, address _evOption, address _oracle)
        Ownable(initialOwner)
    {
        require(_evOption != address(0), "iCDS: zero evOption");
        require(_oracle   != address(0), "iCDS: zero oracle");
        evOption = IEverlastingOption(_evOption);
        oracle   = IOracleAdapter(_oracle);
    }

    function setKeeper(address keeper, bool status) external onlyOwner {
        authorisedKeepers[keeper] = status;
        emit KeeperSet(keeper, status);
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────
    //  Seller: open protection
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Protection seller opens a protection offer by depositing collateral.
     *
     *         The recoveryFloor = recoveryRateWad × current oracle spot.
     *         This is the strike for the everlasting put used in premium computation.
     *
     * @param refAsset        Reference market asset (oracle + evOption key).
     * @param token           Collateral / premium token.
     * @param notional        Protection amount (raw token units). Seller deposits this.
     * @param recoveryRateWad Expected recovery on default (WAD). E.g. 40e16 = 40% recovery.
     *                        Loss-given-default = (1 − recoveryRateWad).
     * @param tenorDays       Protection tenor in days (1–3650).
     * @return id             Protection identifier.
     */
    function openProtection(
        address refAsset,
        address token,
        uint256 notional,
        uint256 recoveryRateWad,
        uint256 tenorDays
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        require(refAsset != address(0) && token != address(0), "iCDS: zero addr");
        require(notional > 0,                   "iCDS: zero notional");
        require(recoveryRateWad < WAD,           "iCDS: recovery >= 100%");
        require(tenorDays > 0 && tenorDays <= 3650, "iCDS: bad tenor");

        // Recovery floor for premium pricing (in WAD)
        uint256 spotWad          = oracle.getIndexPrice(refAsset);
        uint256 recoveryFloorWad = (spotWad * recoveryRateWad) / WAD;

        id = _nextId++;

        protections[id] = Protection({
            seller:            msg.sender,
            buyer:             address(0),
            refAsset:          refAsset,
            token:             token,
            notional:          notional,
            recoveryRateWad:   recoveryRateWad,
            recoveryFloorWad:  recoveryFloorWad,
            tenorEnd:          block.timestamp + tenorDays * 1 days,
            lastPremiumAt:     0,
            premiumsCollected: 0,
            triggeredAt:       0,
            status:            Status.Open
        });

        // Seller deposits full notional as collateral (anti-naked-CDS)
        IERC20(token).safeTransferFrom(msg.sender, address(this), notional);

        emit ProtectionOpened(id, msg.sender, refAsset, token, notional, protections[id].tenorEnd);
    }

    // ─────────────────────────────────────────────────────────────
    //  Buyer: accept protection
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Buyer accepts an open protection offer and pays the first premium.
     *
     *         First premium = Π_put(currentSpot, recoveryFloor) × notional / WAD
     *
     *         The first premium is sent directly to the seller (not held by the contract)
     *         as it is the seller's compensation for posting collateral.
     *
     * @param id Protection identifier.
     */
    function acceptProtection(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Open,     "iCDS: not open");
        require(prot.buyer  == address(0),      "iCDS: already accepted");
        require(block.timestamp < prot.tenorEnd, "iCDS: expired");

        prot.buyer         = msg.sender;
        prot.lastPremiumAt = block.timestamp;
        prot.status        = Status.Active;

        // First premium
        uint256 premium = _computePremium(prot);
        if (premium > 0) {
            IERC20(prot.token).safeTransferFrom(msg.sender, prot.seller, premium);
            prot.premiumsCollected += premium;
            emit PremiumPaid(id, msg.sender, premium);
        }

        emit ProtectionAccepted(id, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────
    //  Buyer: pay periodic premium
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Pay the next quarterly premium. Premium adjusts dynamically with market:
     *         premium = Π_put(currentSpot, recoveryFloor) × notional / WAD
     *
     *         If oracle spot has fallen towards recoveryFloor, the put price increases,
     *         meaning the buyer pays more — reflecting the increased credit risk.
     *         This is unlike conventional CDS fixed spreads (no riba element).
     *
     * @param id Protection identifier.
     */
    function payPremium(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status  == Status.Active,          "iCDS: not active");
        require(msg.sender   == prot.buyer,             "iCDS: not buyer");
        require(block.timestamp >= prot.lastPremiumAt + PREMIUM_PERIOD, "iCDS: too soon");

        uint256 premium = _computePremium(prot);
        require(premium > 0, "iCDS: zero premium");

        // H-6 fix: advance by exactly one PREMIUM_PERIOD (not to block.timestamp).
        // If multiple periods have elapsed the buyer must call payPremium once per
        // period, each time advancing the clock by exactly PREMIUM_PERIOD.
        // Setting to block.timestamp would let a buyer skip N-1 missed periods by
        // paying only a single premium — a seller-side value extraction.
        prot.lastPremiumAt     += PREMIUM_PERIOD;
        prot.premiumsCollected += premium;

        IERC20(prot.token).safeTransferFrom(msg.sender, prot.seller, premium);
        emit PremiumPaid(id, msg.sender, premium);
    }

    // ─────────────────────────────────────────────────────────────
    //  Keeper: trigger credit event
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Trigger a credit event. Callable only by authorised keepers.
     *
     *         On-chain oracle must confirm: spot ≤ recoveryFloor.
     *         This eliminates the gharar objection: the credit event is
     *         objectively verifiable, not defined by a committee.
     *
     * @param id Protection identifier.
     */
    function triggerCreditEvent(uint256 id) external whenNotPaused {
        require(authorisedKeepers[msg.sender], "iCDS: not keeper");
        Protection storage prot = protections[id];
        require(prot.status     == Status.Active, "iCDS: not active");
        require(block.timestamp <  prot.tenorEnd, "iCDS: expired");

        uint256 spotWad = oracle.getIndexPrice(prot.refAsset);
        require(spotWad <= prot.recoveryFloorWad, "iCDS: no default");

        prot.status      = Status.Triggered;
        prot.triggeredAt = block.timestamp;   // starts the SETTLEMENT_WINDOW clock
        emit CreditEventTriggered(id, msg.sender, spotWad, prot.recoveryFloorWad);
    }

    // ─────────────────────────────────────────────────────────────
    //  Buyer: settle payout
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Buyer receives payout after a credit event is triggered.
     *
     *         lossGivenDefault = notional × (1 − recoveryRate)
     *
     *         The remaining recovery portion (notional × recoveryRate) is returned
     *         to the seller — consistent with the mutual takaful principle that
     *         the seller is not penalised beyond the actual loss-given-default.
     *
     * @param id Protection identifier.
     */
    function settle(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status  == Status.Triggered, "iCDS: not triggered");
        require(msg.sender   == prot.buyer,       "iCDS: not buyer");
        // Buyer must settle within SETTLEMENT_WINDOW from the trigger timestamp.
        // After the window passes, expireTrigger() releases the seller's collateral.
        require(
            block.timestamp <= prot.triggeredAt + SETTLEMENT_WINDOW,
            "iCDS: settlement window expired"
        );

        prot.status = Status.Settled;

        // Loss-given-default: notional × (1 − recovery)
        uint256 loss         = (prot.notional * (WAD - prot.recoveryRateWad)) / WAD;
        uint256 payout       = loss > prot.notional ? prot.notional : loss;
        uint256 sellerReturn = prot.notional - payout;

        // CEI: state updated above; transfers below
        if (sellerReturn > 0) IERC20(prot.token).safeTransfer(prot.seller, sellerReturn);
        IERC20(prot.token).safeTransfer(prot.buyer, payout);

        emit Settled(id, prot.buyer, payout, sellerReturn);
    }

    // ─────────────────────────────────────────────────────────────
    //  Seller: expire (no default)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Seller reclaims full notional collateral after protection expires
     *         without a credit event having been triggered.
     *
     *         Also works for Open (unaccepted) protection that has passed tenor end.
     *
     * @param id Protection identifier.
     */
    function expire(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(
            prot.status == Status.Active || prot.status == Status.Open,
            "iCDS: cannot expire"
        );
        require(block.timestamp >= prot.tenorEnd, "iCDS: not expired");
        require(msg.sender == prot.seller,        "iCDS: not seller");

        prot.status = Status.Expired;

        IERC20(prot.token).safeTransfer(prot.seller, prot.notional);
        emit Expired(id, prot.seller, prot.notional);
    }

    // ─────────────────────────────────────────────────────────────
    //  Anyone: expire a stale trigger
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Expire a Triggered protection whose settlement window has elapsed
     *         without the buyer calling settle(). Returns full notional to the seller.
     *         Callable by anyone — the function is permissionless so automated keepers
     *         can maintain contract hygiene without owner involvement.
     *
     *         This prevents the buyer griefing attack where the buyer holds the seller's
     *         collateral locked indefinitely (or waits for price recovery before settling
     *         a trigger that was ephemeral).
     *
     * @param id Protection identifier.
     */
    function expireTrigger(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Triggered, "iCDS: not triggered");
        require(
            block.timestamp > prot.triggeredAt + SETTLEMENT_WINDOW,
            "iCDS: window still open"
        );

        prot.status = Status.Expired;

        // Return full notional to seller — the credit event was not settled in time
        IERC20(prot.token).safeTransfer(prot.seller, prot.notional);
        emit TriggerExpired(id, msg.sender, prot.seller, prot.notional);
    }

    // ─────────────────────────────────────────────────────────────
    //  View
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Compute the current periodic premium for a protection at today's spot.
     *         premium = Π_put(spot, recoveryFloor) × notional / WAD
     *
     * @param id Protection identifier.
     * @return premium Token raw units to be paid as the next quarterly premium.
     */
    function computePremium(uint256 id) external view returns (uint256) {
        return _computePremium(protections[id]);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal
    // ─────────────────────────────────────────────────────────────

    function _computePremium(Protection storage prot) internal view returns (uint256) {
        if (prot.recoveryFloorWad == 0) return 0;
        uint256 spotWad    = oracle.getIndexPrice(prot.refAsset);
        if (spotWad == 0)  return 0;
        uint256 putRateWad = evOption.quotePut(prot.refAsset, spotWad, prot.recoveryFloorWad);
        return (putRateWad * prot.notional) / WAD;
    }
}
