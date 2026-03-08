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
 * @author Baraka Protocol v2
 * @notice Islamic Credit Default Swap — riba-free credit protection using
 *         everlasting put pricing (Ackerer Prop 6, iota=0).
 *
 *         Ported from v1. Key change: uses bytes32 marketId instead of address asset.
 *         All audit fixes preserved (H-5 grace period, H-6 premium lock, iCDS-H-2, etc.)
 */
contract iCDS is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant PREMIUM_PERIOD = 90 days;
    uint256 public constant SETTLEMENT_WINDOW = 7 days;
    uint256 public constant GRACE_PERIOD = 7 days;

    IEverlastingOption public immutable evOption;
    IOracleAdapter     public immutable oracle;

    uint256 private _nextId;
    mapping(address => bool) public authorisedKeepers;

    enum Status { Open, Active, Triggered, Settled, Expired }

    struct Protection {
        address seller;
        address buyer;
        bytes32 refAsset;       // v2: bytes32 marketId
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

    event ProtectionOpened(uint256 indexed id, address indexed seller, bytes32 refAsset, address token, uint256 notional, uint256 tenorEnd);
    event ProtectionAccepted(uint256 indexed id, address indexed buyer);
    event PremiumPaid(uint256 indexed id, address indexed buyer, uint256 amount);
    event CreditEventTriggered(uint256 indexed id, address indexed keeper, uint256 spotWad, uint256 floorWad);
    event Settled(uint256 indexed id, address indexed buyer, uint256 payout, uint256 sellerReturn);
    event Expired(uint256 indexed id, address indexed seller, uint256 collateralReturned);
    event TriggerExpired(uint256 indexed id, address indexed caller, address indexed seller, uint256 collateralReturned);
    event ProtectionTerminated(uint256 indexed id, address indexed seller, uint256 collateralReturned);
    event KeeperSet(address indexed keeper, bool status);

    constructor(address initialOwner, address _evOption, address _oracle) Ownable(initialOwner) {
        require(_evOption != address(0), "iCDS: zero evOption");
        require(_oracle != address(0), "iCDS: zero oracle");
        evOption = IEverlastingOption(_evOption);
        oracle = IOracleAdapter(_oracle);
    }

    function setKeeper(address keeper, bool status) external onlyOwner {
        authorisedKeepers[keeper] = status;
        emit KeeperSet(keeper, status);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("iCDS: renounce disabled");
    }

    function openProtection(
        bytes32 refAsset,
        address token,
        uint256 notional,
        uint256 recoveryRateWad,
        uint256 tenorDays
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        require(token != address(0), "iCDS: zero addr");
        require(notional > 0, "iCDS: zero notional");
        require(recoveryRateWad > 0 && recoveryRateWad < WAD, "iCDS: bad recovery rate");
        require(tenorDays > 0 && tenorDays <= 3650, "iCDS: bad tenor");

        /// AUDIT FIX (P5-M-10): Oracle staleness check — a stale low price creates an
        /// unrealistically low recovery floor, making credit events trivially triggerable.
        require(!oracle.isStale(refAsset), "iCDS: oracle stale");
        uint256 spotWad = oracle.getIndexPrice(refAsset);
        uint256 recoveryFloorWad = (spotWad * recoveryRateWad) / WAD;

        id = _nextId++;

        protections[id] = Protection({
            seller: msg.sender,
            buyer: address(0),
            refAsset: refAsset,
            token: token,
            notional: notional,
            recoveryRateWad: recoveryRateWad,
            recoveryFloorWad: recoveryFloorWad,
            tenorEnd: block.timestamp + tenorDays * 1 days,
            lastPremiumAt: 0,
            premiumsCollected: 0,
            triggeredAt: 0,
            status: Status.Open
        });

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), notional);
        require(IERC20(token).balanceOf(address(this)) - balBefore == notional, "iCDS: fee-on-transfer not supported");

        emit ProtectionOpened(id, msg.sender, refAsset, token, notional, protections[id].tenorEnd);
    }

    function cancelProtection(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Open, "iCDS: not open");
        require(msg.sender == prot.seller, "iCDS: not seller");
        prot.status = Status.Expired;
        IERC20(prot.token).safeTransfer(prot.seller, prot.notional);
        emit Expired(id, prot.seller, prot.notional);
    }

    function acceptProtection(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Open, "iCDS: not open");
        require(prot.buyer == address(0), "iCDS: already accepted");
        require(block.timestamp < prot.tenorEnd, "iCDS: expired");

        prot.buyer = msg.sender;
        prot.lastPremiumAt = block.timestamp;
        prot.status = Status.Active;

        uint256 premium = _computePremium(prot);
        if (premium > 0) {
            IERC20(prot.token).safeTransferFrom(msg.sender, prot.seller, premium);
            prot.premiumsCollected += premium;
            emit PremiumPaid(id, msg.sender, premium);
        }

        emit ProtectionAccepted(id, msg.sender);
    }

    function payPremium(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Active, "iCDS: not active");
        require(msg.sender == prot.buyer, "iCDS: not buyer");
        require(block.timestamp >= prot.lastPremiumAt + PREMIUM_PERIOD, "iCDS: too soon");

        uint256 premium = _computePremium(prot);
        require(premium > 0, "iCDS: zero premium");

        prot.lastPremiumAt += PREMIUM_PERIOD; // H-6 fix: advance by exactly one period
        prot.premiumsCollected += premium;

        IERC20(prot.token).safeTransferFrom(msg.sender, prot.seller, premium);
        emit PremiumPaid(id, msg.sender, premium);
    }

    /// AUDIT FIX (L4-L-2): Added nonReentrant — state changes + external oracle call
    function triggerCreditEvent(uint256 id) external nonReentrant whenNotPaused {
        require(authorisedKeepers[msg.sender], "iCDS: not keeper");
        Protection storage prot = protections[id];
        require(prot.status == Status.Active, "iCDS: not active");
        require(block.timestamp < prot.tenorEnd, "iCDS: expired");

        /// AUDIT FIX (P5-M-8): Oracle staleness check — prevents triggering credit event
        /// using a stale low price that has since recovered. expire() and terminateForNonPayment()
        /// already check isStale(); this was the only path missing it.
        require(!oracle.isStale(prot.refAsset), "iCDS: oracle stale");
        uint256 spotWad = oracle.getIndexPrice(prot.refAsset);
        require(spotWad <= prot.recoveryFloorWad, "iCDS: no default");

        prot.status = Status.Triggered;
        prot.triggeredAt = block.timestamp;
        emit CreditEventTriggered(id, msg.sender, spotWad, prot.recoveryFloorWad);
    }

    /// AUDIT FIX (P3-INST-2): Removed whenNotPaused — settle() must be pause-immune within settlement window.
    /// The 7-day settlement window is time-bounded; pausing the contract during this window would lock the
    /// buyer out of their credit protection payout and allow the seller to reclaim full notional via
    /// expireTrigger() after the window expires. Settlement of a Triggered protection is a claim right,
    /// not an operational action, and must proceed regardless of protocol pause state.
    function settle(uint256 id) external nonReentrant {
        Protection storage prot = protections[id];
        require(prot.status == Status.Triggered, "iCDS: not triggered");
        require(msg.sender == prot.buyer, "iCDS: not buyer");
        require(block.timestamp <= prot.triggeredAt + SETTLEMENT_WINDOW, "iCDS: settlement window expired");

        prot.status = Status.Settled;

        uint256 loss = (prot.notional * (WAD - prot.recoveryRateWad)) / WAD;
        uint256 payout = loss > prot.notional ? prot.notional : loss;
        uint256 sellerReturn = prot.notional - payout;

        if (sellerReturn > 0) IERC20(prot.token).safeTransfer(prot.seller, sellerReturn);
        IERC20(prot.token).safeTransfer(prot.buyer, payout);

        emit Settled(id, prot.buyer, payout, sellerReturn);
    }

    function expire(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Active || prot.status == Status.Open, "iCDS: cannot expire");
        require(block.timestamp >= prot.tenorEnd, "iCDS: not expired");
        require(msg.sender == prot.seller, "iCDS: not seller");

        /// AUDIT FIX (P2-HIGH-3): Block expire() if a credit event is currently active.
        /// Without this check, seller can race expire() vs triggerCreditEvent() at tenor boundary
        /// and reclaim full notional even though the buyer is entitled to a payout.
        /// AUDIT FIX (P3-INST-1): Added staleness check — stale oracle returns pre-default price,
        /// allowing seller to call expire() during a real credit event (oracle hasn't updated yet).
        /// terminateForNonPayment() correctly checks isStale(); same guard required here.
        if (prot.status == Status.Active) {
            require(!oracle.isStale(prot.refAsset), "iCDS: oracle stale");
            uint256 spotWad = oracle.getIndexPrice(prot.refAsset);
            require(spotWad > prot.recoveryFloorWad, "iCDS: credit event active, use triggerCreditEvent");
        }

        prot.status = Status.Expired;
        IERC20(prot.token).safeTransfer(prot.seller, prot.notional);
        emit Expired(id, prot.seller, prot.notional);
    }

    function terminateForNonPayment(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Active, "iCDS: not active");
        require(msg.sender == prot.seller, "iCDS: only seller");
        require(block.timestamp > prot.lastPremiumAt + PREMIUM_PERIOD + GRACE_PERIOD, "iCDS: grace period not elapsed");

        /// AUDIT FIX (ICDS-M-1): Require fresh oracle — seller cannot terminate during oracle outage
        require(!oracle.isStale(prot.refAsset), "iCDS: oracle stale");
        uint256 spotWad = oracle.getIndexPrice(prot.refAsset);
        require(spotWad > 0, "iCDS: zero spot");
        require(spotWad > prot.recoveryFloorWad, "iCDS: credit event active, cannot terminate");

        prot.status = Status.Expired;
        IERC20(prot.token).safeTransfer(prot.seller, prot.notional);
        /// @dev INFO (L4-I-2): ProtectionTerminated event includes seller address and notional returned.
        emit ProtectionTerminated(id, prot.seller, prot.notional);
    }

    function expireTrigger(uint256 id) external nonReentrant whenNotPaused {
        Protection storage prot = protections[id];
        require(prot.status == Status.Triggered, "iCDS: not triggered");
        require(block.timestamp > prot.triggeredAt + SETTLEMENT_WINDOW, "iCDS: window still open");
        /// AUDIT FIX (L4-L-3): Restrict to keeper or seller — prevents griefing by arbitrary callers
        require(authorisedKeepers[msg.sender] || msg.sender == prot.seller, "iCDS: not keeper or seller");

        prot.status = Status.Expired;
        IERC20(prot.token).safeTransfer(prot.seller, prot.notional);
        emit TriggerExpired(id, msg.sender, prot.seller, prot.notional);
    }

    function computePremium(uint256 id) external view returns (uint256) {
        return _computePremium(protections[id]);
    }

    function _computePremium(Protection storage prot) internal view returns (uint256) {
        if (prot.recoveryFloorWad == 0) return 0;
        /// AUDIT FIX (ICDS-M-2): Revert on stale oracle instead of returning 0 — prevents
        /// buyer missing payment due to oracle outage and subsequent non-payment termination
        require(!oracle.isStale(prot.refAsset), "iCDS: oracle stale for premium");
        uint256 spotWad = oracle.getIndexPrice(prot.refAsset);
        require(spotWad > 0, "iCDS: zero spot for premium");
        uint256 putRateWad = evOption.quotePut(prot.refAsset, spotWad, prot.recoveryFloorWad);
        return (putRateWad * prot.notional) / WAD;
    }
}
