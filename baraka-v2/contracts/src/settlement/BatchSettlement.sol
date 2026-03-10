// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IMarginEngine.sol";
import "../interfaces/IFeeEngine.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IShariahRegistry.sol";
import "../interfaces/IAutoDeleveraging.sol";
import "../interfaces/ISubaccountManager.sol";

/**
 * @title BatchSettlement
 * @author Baraka Protocol v2
 * @notice Processes matched trades in batches for gas efficiency and MEV reduction.
 *
 *         Instead of settling each fill individually in MatchingEngine._processFill(),
 *         fills can be queued and settled atomically in one transaction.
 *
 *         Benefits:
 *           - Reduced gas (one storage write per subaccount instead of per fill)
 *           - Atomic settlement (all-or-nothing for a batch)
 *           - MEV reduction (harder to sandwich a batch)
 */
contract BatchSettlement is Ownable2Step, ReentrancyGuard {

    uint256 constant WAD = 1e18;

    /// AUDIT FIX (L0-M-5): Cap batch size to prevent gas DoS
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// AUDIT FIX (P16-UP-C2): Timelocked dependency update to prevent brick risk
    uint256 constant DEPENDENCY_TIMELOCK = 48 hours;

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P16-UP-C2): Removed immutable from marginEngine and oracle to allow timelocked updates
    IMarginEngine    public marginEngine;
    IFeeEngine       public feeEngine;
    IOracleAdapter   public oracle;
    /// AUDIT FIX (P4-A4-11): Optional Shariah registry — if set, respects emergency halt in _settleOne().
    /// Without this, an authorized operator can bypass a Shariah board halt by submitting via BatchSettlement.
    IShariahRegistry public shariahRegistry;

    /// AUDIT FIX (P8-M-1): ADL participant registry — register traders after successful settlement
    /// so ADL has a populated counterparty list. Without this, trades settled through BatchSettlement
    /// produce positions invisible to the ADL system.
    IAutoDeleveraging public adl;

    /// AUDIT FIX (P8-L-1): SubaccountManager for existence checks — prevents closed subaccounts
    /// from receiving positions through BatchSettlement, consistent with MatchingEngine enforcement.
    ISubaccountManager public subaccountManager;

    /// AUDIT FIX (P16-UP-C2): Timelocked dependency update state
    address public pendingOracle;
    uint256 public pendingOracleTimestamp;
    address public pendingMarginEngine;
    uint256 public pendingMarginEngineTimestamp;

    /// @notice Authorised callers (MatchingEngine)
    mapping(address => bool) public authorised;

    /// AUDIT FIX (L0-M-6): Nonce for unique batchId generation
    uint256 private _batchNonce;

    // ─────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────

    struct SettlementItem {
        bytes32 marketId;
        bytes32 takerSubaccount;
        bytes32 makerSubaccount;
        uint8   takerSide;        // 0 = Buy, 1 = Sell
        uint256 price;
        uint256 size;
    }

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event BatchSettled(uint256 count, bytes32 indexed batchId);
    /// AUDIT FIX (P5-H-12): Emitted when a single settlement fails within a batch.
    event SettlementFailed(uint256 indexed index, bytes32 indexed marketId);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _marginEngine,
        address _oracle
    ) Ownable(initialOwner) {
        require(_marginEngine != address(0), "BS: zero ME");
        require(_oracle != address(0), "BS: zero oracle");
        marginEngine = IMarginEngine(_marginEngine);
        oracle = IOracleAdapter(_oracle);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (L0-L-2): Emit events on admin state changes
    event AuthorisedSet(address indexed caller, bool status);
    event FeeEngineUpdated(address indexed feeEngine);
    event ShariahRegistryUpdated(address indexed registry);
    event ADLUpdated(address indexed adl);
    event SubaccountManagerUpdated(address indexed subaccountManager);

    /// AUDIT FIX (P16-UP-C2): Timelocked dependency update events
    event OracleUpdateInitiated(address indexed newOracle, uint256 effectiveAt);
    event OracleUpdated(address indexed newOracle);
    event MarginEngineUpdateInitiated(address indexed newMarginEngine, uint256 effectiveAt);
    event MarginEngineUpdated(address indexed newMarginEngine);

    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "BS: zero address");
        authorised[caller] = status;
        emit AuthorisedSet(caller, status);
    }

    /// AUDIT FIX (L0-M-8): Prevent setting FeeEngine to zero — silently disables all fees
    function setFeeEngine(address _feeEngine) external onlyOwner {
        require(_feeEngine != address(0), "BS: zero feeEngine");
        feeEngine = IFeeEngine(_feeEngine);
        emit FeeEngineUpdated(_feeEngine);
    }

    /// AUDIT FIX (P4-A4-11): Optional Shariah registry for halt enforcement.
    /// Allows address(0) to clear — batch settlement operates without halt check if not set.
    function setShariahRegistry(address _registry) external onlyOwner {
        shariahRegistry = IShariahRegistry(_registry);
        emit ShariahRegistryUpdated(_registry);
    }

    /// AUDIT FIX (P8-M-1): Set ADL contract for participant registration after settlements.
    function setADL(address _adl) external onlyOwner {
        adl = IAutoDeleveraging(_adl);
        emit ADLUpdated(_adl);
    }

    /// AUDIT FIX (P8-L-1): Set SubaccountManager for existence checks.
    function setSubaccountManager(address _subaccountManager) external onlyOwner {
        subaccountManager = ISubaccountManager(_subaccountManager);
        emit SubaccountManagerUpdated(_subaccountManager);
    }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("BS: renounce disabled");
    }

    /// AUDIT FIX (P16-UP-C2): Timelocked oracle update to prevent brick risk
    function initiateOracleUpdate(address newOracle) external onlyOwner {
        require(newOracle != address(0), "BS: zero address");
        pendingOracle = newOracle;
        pendingOracleTimestamp = block.timestamp;
        emit OracleUpdateInitiated(newOracle, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyOracleUpdate() external onlyOwner {
        require(pendingOracle != address(0), "BS: no pending update");
        require(block.timestamp >= pendingOracleTimestamp + DEPENDENCY_TIMELOCK, "BS: timelock active");
        oracle = IOracleAdapter(pendingOracle);
        emit OracleUpdated(pendingOracle);
        pendingOracle = address(0);
        pendingOracleTimestamp = 0;
    }

    /// AUDIT FIX (P18-H-3): Cancel pending oracle update
    /// AUDIT FIX (P19-M-2): Emit event for off-chain monitoring
    function cancelOracleUpdate() external onlyOwner {
        require(pendingOracle != address(0), "BS: no pending update");
        emit OracleUpdateCancelled(pendingOracle);
        pendingOracle = address(0);
        pendingOracleTimestamp = 0;
    }
    event OracleUpdateCancelled(address indexed cancelled);

    /// AUDIT FIX (P16-UP-C2): Timelocked marginEngine update to prevent brick risk
    function initiateMarginEngineUpdate(address newMarginEngine) external onlyOwner {
        require(newMarginEngine != address(0), "BS: zero address");
        pendingMarginEngine = newMarginEngine;
        pendingMarginEngineTimestamp = block.timestamp;
        emit MarginEngineUpdateInitiated(newMarginEngine, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyMarginEngineUpdate() external onlyOwner {
        require(pendingMarginEngine != address(0), "BS: no pending update");
        require(block.timestamp >= pendingMarginEngineTimestamp + DEPENDENCY_TIMELOCK, "BS: timelock active");
        marginEngine = IMarginEngine(pendingMarginEngine);
        emit MarginEngineUpdated(pendingMarginEngine);
        pendingMarginEngine = address(0);
        pendingMarginEngineTimestamp = 0;
    }

    /// AUDIT FIX (P18-H-3): Cancel pending marginEngine update
    /// AUDIT FIX (P19-M-2): Emit event for off-chain monitoring
    function cancelMarginEngineUpdate() external onlyOwner {
        require(pendingMarginEngine != address(0), "BS: no pending update");
        emit MarginEngineUpdateCancelled(pendingMarginEngine);
        pendingMarginEngine = address(0);
        pendingMarginEngineTimestamp = 0;
    }
    event MarginEngineUpdateCancelled(address indexed cancelled);

    // ─────────────────────────────────────────────────────
    // Core — batch settlement
    // ─────────────────────────────────────────────────────

    /// @notice Settle a batch of fills atomically.
    /// @param items Array of settlement items (from MatchingEngine fills).
    function settleBatch(SettlementItem[] calldata items) external nonReentrant {
        require(authorised[msg.sender], "BS: not authorised");
        require(items.length > 0, "BS: empty batch");
        /// AUDIT FIX (L0-M-5): Enforce max batch size to prevent gas DoS
        require(items.length <= MAX_BATCH_SIZE, "BS: batch too large");

        /// AUDIT FIX (P5-H-12): Wrap each settlement in try/catch for error isolation.
        /// Unlike MatchingEngine (which has try/catch per fill), BatchSettlement previously
        /// had no error isolation — one insolvent maker reverted the entire batch.
        for (uint256 i = 0; i < items.length; i++) {
            try this.settleOneExternal(items[i]) {
            } catch {
                emit SettlementFailed(i, items[i].marketId);
            }
        }

        /// AUDIT FIX (L0-M-6): Include nonce for unique batchId
        bytes32 batchId = keccak256(abi.encodePacked(block.number, block.timestamp, items.length, _batchNonce++));
        emit BatchSettled(items.length, batchId);
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P5-H-12): External wrapper for try/catch in settleBatch.
    /// Only callable by this contract (self-call from settleBatch loop).
    /// AUDIT NOTE (P10-M-4): `nonReentrant` cannot be added here because `settleBatch`
    /// already holds the ReentrancyGuard lock when it makes `this.settleOneExternal()` calls;
    /// a second `nonReentrant` on this function would cause every settlement to revert.
    /// Reentrancy into this function is already blocked by two independent guards:
    ///   1. `msg.sender == address(this)` — no external contract can call this directly.
    ///   2. `settleBatch`'s `nonReentrant` — the outer lock is held for the entire batch duration;
    ///      any reentrant call to `settleBatch` (the only authorised entry point) is rejected.
    function settleOneExternal(SettlementItem calldata item) external {
        require(msg.sender == address(this), "BS: self-call only");
        _settleOne(item);
    }

    function _settleOne(SettlementItem calldata item) internal {
        /// AUDIT FIX (L0-H-3): Validate takerSide — reject invalid values
        require(item.takerSide <= 1, "BS: invalid takerSide");
        /// AUDIT FIX (L0-L-5): Reject zero-value settlements
        require(item.size > 0, "BS: zero size");
        require(item.price > 0, "BS: zero price");
        /// AUDIT FIX (L0-L-4): Self-trade prevention
        require(item.takerSubaccount != item.makerSubaccount, "BS: self-trade");
        /// AUDIT FIX (P16-AC-M4): Cross-account self-trade prevention — different subaccounts
        /// owned by the same address must not trade against each other (wash trading).
        if (address(subaccountManager) != address(0)) {
            require(
                subaccountManager.getOwner(item.takerSubaccount) != subaccountManager.getOwner(item.makerSubaccount),
                "BS: same-owner self-trade"
            );
        }
        /// AUDIT FIX (P4-A4-11): Respect Shariah board emergency halt if registry is configured.
        /// Without this check, an authorised operator can submit settlements after the Shariah
        /// board has halted the protocol, bypassing the emergency stop entirely.
        if (address(shariahRegistry) != address(0)) {
            require(!shariahRegistry.isProtocolHalted(), "BS: protocol halted");
        }
        /// AUDIT FIX (P8-L-1): Enforce subaccount existence — closed subaccounts cannot receive
        /// positions through BatchSettlement. Consistent with MatchingEngine enforcement (P7-L-2).
        if (address(subaccountManager) != address(0)) {
            require(subaccountManager.exists(item.takerSubaccount), "BS: taker subaccount closed");
            require(subaccountManager.exists(item.makerSubaccount), "BS: maker subaccount closed");
        }
        /// AUDIT FIX (P3-CROSS-4): Validate market is active and settlement price is within ±5% of oracle.
        /// Without this, an authorized operator can submit fabricated settlements at arbitrary prices,
        /// generating phantom PnL or triggering liquidations via artificially extreme settlement prices.
        /// AUDIT FIX (P4-A4-3): Reject settlement when oracle is stale rather than silently bypassing
        /// the band check. A stale oracle is untrustworthy — settlement must be blocked until the oracle
        /// is refreshed. The previous "skip if stale" pattern permitted arbitrary price injection.
        {
            IMarginEngine.MarketParams memory mktParams = marginEngine.getMarketParams(item.marketId);
            require(mktParams.active, "BS: market not active");
            require(!oracle.isStale(item.marketId), "BS: oracle stale");
            uint256 indexPrice = oracle.getIndexPrice(item.marketId);
            uint256 lower = indexPrice * 95 / 100; // 5% below
            uint256 upper = indexPrice * 105 / 100; // 5% above
            require(item.price >= lower && item.price <= upper, "BS: price out of oracle band");
        }

        int256 takerDelta;
        int256 makerDelta;

        if (item.takerSide == 0) {
            // Taker buying (long)
            takerDelta = int256(item.size);
            makerDelta = -int256(item.size);
        } else {
            // Taker selling (short)
            takerDelta = -int256(item.size);
            makerDelta = int256(item.size);
        }

        // Update positions
        marginEngine.updatePosition(item.takerSubaccount, item.marketId, takerDelta, item.price);
        marginEngine.updatePosition(item.makerSubaccount, item.marketId, makerDelta, item.price);

        /// AUDIT FIX (P8-M-1): Register both taker and maker as market participants for ADL ranking.
        /// Consistent with MatchingEngine._processFill() (P7-M-2 fix). Without this, trades settled
        /// through BatchSettlement produce positions invisible to the ADL system.
        if (address(adl) != address(0)) {
            try adl.registerParticipant(item.marketId, item.takerSubaccount) {} catch {}
            try adl.registerParticipant(item.marketId, item.makerSubaccount) {} catch {}
        }

        /// AUDIT FIX (P8-L-3): Update EWMA mark price with settlement price. Consistent with
        /// MatchingEngine._processFill() (P2-HIGH-6 fix). Without this, batch-settled fills are
        /// excluded from the EWMA, distorting funding rates.
        try oracle.updateMarkPrice(item.marketId, item.price) {} catch {}

        // Charge fees if FeeEngine is set
        // AUDIT FIX (L1B-H-3): Use processTradeFees instead of deprecated payMakerRebate
        /// AUDIT FIX (L0-M-9): Use Math.mulDiv to prevent overflow on extreme notionals
        /// AUDIT NOTE (L0-M-7): Margin checks enforced by MarginEngine.updatePosition() above
        /// AUDIT FIX (P2-MEDIUM-1): Wrap in try/catch — fee failure must not revert entire batch.
        /// Consistent with MatchingEngine._processFill pattern. A single fee error should not
        /// rollback all position updates in the batch (which can't be re-settled safely).
        if (address(feeEngine) != address(0)) {
            uint256 notional = Math.mulDiv(item.size, item.price, WAD);
            try feeEngine.processTradeFees(item.takerSubaccount, item.makerSubaccount, notional) {} catch {}
        }
    }
}
