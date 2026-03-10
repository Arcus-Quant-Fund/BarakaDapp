// SPDX-License-Identifier: BUSL-1.1
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
 * @author Baraka Protocol v2
 * @notice Shariah-compliant mutual insurance using everlasting put pricing.
 *
 *         Ported from v1. Key change: uses bytes32 marketId for asset reference.
 *         All audit fixes preserved (TP-H-1, TP-M-1/3/5, H-4, etc.)
 *
 *         AAOIFI Shariah Standard No. 26 — Islamic Insurance (Takaful)
 */
contract TakafulPool is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant WAKALA_FEE_BPS = 1000; // 10%
    uint256 public constant MIN_RESERVE_BPS = 3000; // 30%

    IEverlastingOption public immutable evOption;
    IOracleAdapter     public immutable oracle;
    address            public immutable operator;

    struct Pool {
        bytes32 asset;       // v2: bytes32 marketId
        address token;
        uint256 floorWad;
        bool    active;
    }

    struct Member {
        uint256 totalCoverage;
        uint256 totalTabarru;
        /// AUDIT FIX (P3-INST-7): Track when this member last contributed tabarru.
        /// AUDIT FIX (P4-A3-5): Changed from block.number to block.timestamp. On Arbitrum L2,
        /// block.number returns the L1 block number (~12s intervals), not the L2 block.
        /// Multiple L2 transactions can share the same block.number, rendering the original
        /// same-block cooldown ineffective. Timestamp-based with configurable cooldown is reliable.
        uint256 lastContributeTime;
    }

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => uint256) public poolBalance;
    mapping(bytes32 => mapping(address => Member)) public members;
    mapping(bytes32 => uint256) public totalClaimsPaid;
    /// AUDIT FIX (P15-M-4): Per-period accumulators that reset each surplus distribution cycle.
    /// Prevents monotonically-increasing totalClaimsPaid from permanently blocking surplus.
    mapping(bytes32 => uint256) public periodClaimsPaid;
    mapping(bytes32 => uint256) public periodPremiums;
    mapping(address => bool) public authorisedKeepers;
    mapping(bytes32 => uint256) public lastSurplusDistribution;
    /// AUDIT FIX (TP-M-2): Approved surplus recipients per pool
    mapping(bytes32 => mapping(address => bool)) public approvedSurplusRecipients;
    /// AUDIT FIX (P3-INST-8): Cap on the fraction of total tabarru that a single claim can consume.
    /// Prevents cheap OTM coverage positions from draining the pool in a single keeper-triggered claim.
    /// Configurable by owner; default 10% (0.10e18 in WAD).
    uint256 public maxClaimRatioWad = 0.10e18;
    /// AUDIT FIX (P4-A3-5): Configurable cooldown between contribution and claim eligibility (seconds).
    /// Default 60s — prevents atomic contribute→claim via compromised keeper on Arbitrum L2.
    uint256 public contributionCooldown = 60;

    event PoolCreated(bytes32 indexed poolId, bytes32 asset, address token, uint256 floorWad);
    event FloorUpdated(bytes32 indexed poolId, uint256 newFloorWad);
    event ContributionMade(bytes32 indexed poolId, address indexed member, uint256 coverage, uint256 tabarru, uint256 wakala);
    event ClaimPaid(bytes32 indexed poolId, address indexed beneficiary, uint256 amount);
    event SurplusDistributed(bytes32 indexed poolId, address indexed recipient, uint256 amount);
    event KeeperSet(address indexed keeper, bool status);

    constructor(
        address initialOwner,
        address _evOption,
        address _oracle,
        address _operator
    ) Ownable(initialOwner) {
        require(_evOption != address(0), "TP: zero evOption");
        require(_oracle != address(0), "TP: zero oracle");
        require(_operator != address(0), "TP: zero operator");
        evOption = IEverlastingOption(_evOption);
        oracle = IOracleAdapter(_oracle);
        operator = _operator;
    }

    function createPool(bytes32 poolId, bytes32 asset, address token, uint256 floorWad) external onlyOwner {
        require(token != address(0), "TP: zero addr");
        require(floorWad > 0, "TP: zero floor");
        require(!pools[poolId].active, "TP: pool exists");
        pools[poolId] = Pool({ asset: asset, token: token, floorWad: floorWad, active: true });
        emit PoolCreated(poolId, asset, token, floorWad);
    }

    /// AUDIT FIX (P19-L-5): Add zero-address check consistent with all other contracts
    function setKeeper(address keeper, bool status) external onlyOwner {
        require(keeper != address(0), "TP: zero keeper");
        authorisedKeepers[keeper] = status;
        emit KeeperSet(keeper, status);
    }

    /// AUDIT FIX (TP-M-2): Whitelist surplus distribution recipients per pool
    function setSurplusRecipient(bytes32 poolId, address recipient, bool approved) external onlyOwner {
        require(recipient != address(0), "TP: zero recipient");
        approvedSurplusRecipients[poolId][recipient] = approved;
    }

    /// AUDIT FIX (L4-L-6): Allow owner to update floor — markets move, floor must be adjustable
    function setFloorWad(bytes32 poolId, uint256 newFloorWad) external onlyOwner {
        require(pools[poolId].active, "TP: pool inactive");
        require(newFloorWad > 0, "TP: zero floor");
        pools[poolId].floorWad = newFloorWad;
        emit FloorUpdated(poolId, newFloorWad);
    }

    /// AUDIT FIX (P3-INST-8): Allow owner to adjust the per-claim ratio cap. Must be in (0, WAD].
    function setMaxClaimRatioWad(uint256 newRatioWad) external onlyOwner {
        require(newRatioWad > 0 && newRatioWad <= WAD, "TP: invalid claim ratio");
        maxClaimRatioWad = newRatioWad;
    }

    /// AUDIT FIX (P4-A3-5): Allow owner to adjust contribution cooldown.
    /// Capped at 1 hour to prevent accidentally locking claims indefinitely.
    function setContributionCooldown(uint256 cooldownSeconds) external onlyOwner {
        require(cooldownSeconds <= 1 hours, "TP: cooldown > 1 hour");
        contributionCooldown = cooldownSeconds;
    }

    /// AUDIT FIX (L4-I-4): Allow owner to deactivate a pool (wind-down, no new contributions)
    function deactivatePool(bytes32 poolId) external onlyOwner {
        require(pools[poolId].active, "TP: pool inactive");
        pools[poolId].active = false;
    }

    function pause() external onlyOwner { _pause(); }
    // unpause() defined below with emergencyRecovered guard

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("TP: renounce disabled");
    }

    function contribute(bytes32 poolId, uint256 coverageAmount) external nonReentrant whenNotPaused {
        require(coverageAmount > 0, "TP: zero coverage");
        Pool storage p = pools[poolId];
        require(p.active, "TP: pool inactive");

        uint256 spotWad = oracle.getIndexPrice(p.asset);
        require(spotWad > 0, "TP: zero spot");
        /// @dev INFO (L4-I-3): Uses real-time oracle rate for tabarru — this is correct.
        ///      Snapshot rates would be stale and exploitable.
        uint256 putRateWad = evOption.quotePut(p.asset, spotWad, p.floorWad);
        uint256 tabarruGross = (putRateWad * coverageAmount) / WAD;
        require(tabarruGross > 0, "TP: coverage too small");

        uint256 wakala = (tabarruGross * WAKALA_FEE_BPS) / 10_000;
        if (tabarruGross > 0 && wakala == 0) wakala = 1; // TP-M-5 fix
        uint256 tabarru = tabarruGross - wakala;
        /// AUDIT FIX (P16-AR-L1): Prevent zero-tabarru contributions that create free coverage
        require(tabarru > 0, "TP: contribution too small");

        uint256 balBefore = IERC20(p.token).balanceOf(address(this));
        IERC20(p.token).safeTransferFrom(msg.sender, address(this), tabarruGross);
        require(IERC20(p.token).balanceOf(address(this)) - balBefore == tabarruGross, "TP: fee-on-transfer not supported");
        if (wakala > 0) IERC20(p.token).safeTransfer(operator, wakala);

        Member storage m = members[poolId][msg.sender];
        m.totalCoverage += coverageAmount;
        m.totalTabarru += tabarru;
        /// AUDIT FIX (P3-INST-7): Record contribution time for cooldown enforcement.
        /// AUDIT FIX (P4-A3-5): Uses block.timestamp (reliable on L2) instead of block.number.
        m.lastContributeTime = block.timestamp;
        poolBalance[poolId] += tabarru;
        /// AUDIT FIX (P15-M-4): Track per-period premiums for surplus calculation.
        periodPremiums[poolId] += tabarru;

        emit ContributionMade(poolId, msg.sender, coverageAmount, tabarru, wakala);
    }

    function getRequiredTabarru(bytes32 poolId, uint256 coverageAmount)
        external view returns (uint256 tabarruGross, uint256 spotWad, uint256 putRateWad)
    {
        Pool storage p = pools[poolId];
        require(p.active, "TP: pool inactive");
        spotWad = oracle.getIndexPrice(p.asset);
        putRateWad = evOption.quotePut(p.asset, spotWad, p.floorWad);
        tabarruGross = (putRateWad * coverageAmount) / WAD;
    }

    function payClaim(bytes32 poolId, address beneficiary, uint256 amount) external nonReentrant whenNotPaused {
        require(authorisedKeepers[msg.sender], "TP: not keeper");
        Pool storage p = pools[poolId];
        require(p.active, "TP: pool inactive");
        require(beneficiary != address(0), "TP: zero beneficiary");
        require(amount > 0, "TP: zero amount");

        Member storage m = members[poolId][beneficiary];
        require(m.totalCoverage > 0, "TP: not a member");
        require(amount <= m.totalCoverage, "TP: exceeds coverage");

        /// AUDIT FIX (P3-INST-7): Enforce cooldown between contribute and claim.
        /// AUDIT FIX (P4-A3-5): Uses timestamp with configurable cooldown instead of block.number.
        /// On Arbitrum L2, block.number is the L1 block number (~12s intervals), allowing multiple
        /// L2 transactions in the same "block". Timestamp-based cooldown is L2-safe.
        require(block.timestamp >= m.lastContributeTime + contributionCooldown, "TP: contribution cooldown");

        /// AUDIT FIX (P3-INST-6): Verify oracle is not stale before reading spot price for claim
        /// eligibility. Without this check, a claim could be processed against a pre-recovery stale
        /// price even after the protected asset has recovered above the floor.
        require(!oracle.isStale(p.asset), "TP: oracle stale");
        uint256 spotWad = oracle.getIndexPrice(p.asset);
        require(spotWad < p.floorWad, "TP: floor not breached");

        /// AUDIT FIX (P3-INST-8): Cap per-claim payout to maxClaimRatioWad fraction of pool balance.
        /// Prevents a single OTM coverage position from draining the entire tabarru pool.
        uint256 avail = poolBalance[poolId];
        uint256 maxPayable = (avail * maxClaimRatioWad) / WAD;
        uint256 cappedAmount = amount > maxPayable ? maxPayable : amount;
        uint256 payout = cappedAmount > avail ? avail : cappedAmount;
        require(payout > 0, "TP: pool empty");

        poolBalance[poolId] -= payout;
        totalClaimsPaid[poolId] += payout;
        /// AUDIT FIX (P15-M-4): Track per-period claims for surplus calculation.
        periodClaimsPaid[poolId] += payout;
        /// AUDIT FIX (TP-M-1): Reduce member's totalCoverage — prevents unlimited repeated claims
        /// AUDIT FIX (P5-H-11): Deduct requested amount, not capped payout. Previously, when
        /// maxClaimRatioWad caps payout to 10% of pool, coverage only decreased by the capped
        /// amount. A member could iterate ~60 claims to drain ~99% of the pool.
        m.totalCoverage -= amount;

        IERC20(p.token).safeTransfer(beneficiary, payout);
        emit ClaimPaid(poolId, beneficiary, payout);
    }

    /// AUDIT FIX (P19-M-11): Track whether emergency recovery has been used.
    /// After recovery, unpause is blocked — contract is in one-way migration mode.
    bool public emergencyRecovered;

    /// AUDIT FIX (P16-UP-H5): Emergency token recovery when contract is paused.
    /// WARNING: This desyncs poolBalance from actual token balances. Contract cannot be
    /// unpaused after recovery — use only for one-way migration to a new contract.
    function emergencyRecoverTokens(address token, address to, uint256 amount) external onlyOwner whenPaused {
        require(to != address(0), "TP: zero recipient");
        emergencyRecovered = true;
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRecovery(token, to, amount);
    }
    event EmergencyRecovery(address indexed token, address indexed to, uint256 amount);

    function unpause() external onlyOwner {
        require(!emergencyRecovered, "TP: cannot unpause after emergency recovery");
        _unpause();
    }

    function distributeSurplus(bytes32 poolId, address recipient) external onlyOwner nonReentrant whenNotPaused {
        Pool storage p = pools[poolId];
        require(p.active, "TP: pool inactive");
        require(recipient != address(0), "TP: zero recipient");
        /// AUDIT FIX (TP-M-2): Only approved recipients can receive surplus — Shariah governance
        require(approvedSurplusRecipients[poolId][recipient], "TP: recipient not approved");
        require(
            lastSurplusDistribution[poolId] == 0 || block.timestamp >= lastSurplusDistribution[poolId] + 30 days,
            "TP: surplus cooldown"
        );

        uint256 balance_ = poolBalance[poolId];
        /// AUDIT FIX (P15-M-4): Use per-period claims instead of monotonically-increasing
        /// totalClaimsPaid. The old formula `2 * totalClaimsPaid` grew without bound,
        /// eventually exceeding balance_ and permanently blocking surplus distribution.
        uint256 claimsReserve = 2 * periodClaimsPaid[poolId];
        uint256 pctReserve = (balance_ * MIN_RESERVE_BPS) / 10_000;
        uint256 reserve = claimsReserve > pctReserve ? claimsReserve : pctReserve;
        require(balance_ > reserve, "TP: no surplus");

        uint256 surplus = balance_ - reserve;
        poolBalance[poolId] -= surplus;
        lastSurplusDistribution[poolId] = block.timestamp;
        /// AUDIT FIX (P15-M-4): Reset per-period accumulators after distribution.
        periodClaimsPaid[poolId] = 0;
        periodPremiums[poolId] = 0;

        IERC20(p.token).safeTransfer(recipient, surplus);
        emit SurplusDistributed(poolId, recipient, surplus);
    }
}
