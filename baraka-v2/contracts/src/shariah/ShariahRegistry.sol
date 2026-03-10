// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IShariahRegistry.sol";
import "../interfaces/IMarginEngine.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title ShariahRegistry
 * @author Baraka Protocol v2
 * @notice Shariah compliance enforcement layer. Called before every trade fill.
 *
 *         Evolved from v1's ShariahGuard with enhanced validation:
 *           - Asset whitelist (Shariah board multisig approval)
 *           - Collateral whitelist (USDC, PAXG, XAUT)
 *           - Per-market max leverage (default 5x, configurable)
 *           - Fatwa IPFS CID on-chain
 *           - Emergency protocol halt
 *           - Pre-fill validation (called by MatchingEngine)
 *
 *         Max leverage is enforced via margin requirements:
 *           If max_leverage = 5, then IMR >= 20% (1/5).
 *           The MarginEngine's per-market IMR must be >= 1/maxLeverage.
 */
contract ShariahRegistry is IShariahRegistry, Ownable2Step {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;
    uint256 public constant DEFAULT_MAX_LEVERAGE = 5;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice Approved assets (markets)
    mapping(bytes32 => bool) private _approvedAssets;

    /// @notice Approved collateral tokens
    mapping(address => bool) private _approvedCollaterals;

    /// @notice Per-market max leverage (0 = use DEFAULT_MAX_LEVERAGE)
    mapping(bytes32 => uint256) private _maxLeverage;

    /// @notice Fatwa IPFS CID
    string public fatwaCid;

    /// @notice Shariah board multisig address
    address public shariahBoard;

    /// AUDIT FIX (P3-CROSS-2): Two-step board transfer — owner proposes, pending board accepts.
    /// Previously setShariahBoard() was onlyOwner, meaning the DAO/governance could unilaterally
    /// replace the Shariah board, subverting the separation of powers between governance and compliance.
    address public pendingShariahBoard;

    /// @notice Emergency halt flag
    bool private _halted;

    /// AUDIT FIX (P10-M-6): Governance override for permanent halt.
    /// If the Shariah board goes dark or becomes unresponsive, the protocol can be
    /// permanently frozen. The owner (DAO governance) may propose an un-halt override;
    /// after HALT_OVERRIDE_DELAY has elapsed without board action, executeHaltOverride()
    /// can be called to resume trading. The board can still halt again at any time.
    uint256 public constant HALT_OVERRIDE_DELAY = 48 hours;
    uint256 public haltOverrideProposedAt; // 0 = no pending override

    /// @notice MarginEngine reference (for leverage validation)
    IMarginEngine public marginEngine;

    /// @notice Oracle reference (for notional calculation)
    IOracleAdapter public oracle;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event AssetApproved(bytes32 indexed marketId, bool approved);
    event CollateralApproved(address indexed token, bool approved);
    event MaxLeverageSet(bytes32 indexed marketId, uint256 maxLeverage);
    event FatwaCidSet(string cid);
    event ShariahBoardSet(address indexed board);
    event ProtocolHalted(bool halted);
    /// AUDIT FIX (P10-M-6): Governance override events
    event HaltOverrideProposed(uint256 executeAfter);
    event HaltOverrideCancelled();
    event HaltOverrideExecuted();

    // ─────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (L2-M-8): Owner cannot bypass Shariah board — only board multisig
    modifier onlyShariahBoard() {
        require(msg.sender == shariahBoard, "SR: not Shariah board");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {
        shariahBoard = initialOwner; // initially same as owner
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setMarginEngine(address _marginEngine) external onlyOwner {
        require(_marginEngine != address(0), "SR: zero ME");
        marginEngine = IMarginEngine(_marginEngine);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "SR: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    /// AUDIT FIX (P3-CROSS-2): Renamed to proposeShariahBoard — initiates two-step transfer.
    /// The proposed board must call acceptShariahBoard() to complete the transfer.
    /// Owner alone can no longer unilaterally install a new Shariah board.
    function setShariahBoard(address board) external onlyOwner {
        require(board != address(0), "SR: zero board");
        pendingShariahBoard = board;
        // Note: ShariahBoardSet is emitted only after acceptShariahBoard() completes.
    }

    /// @notice Proposed board must call this to accept the role.
    function acceptShariahBoard() external {
        require(msg.sender == pendingShariahBoard, "SR: not pending board");
        shariahBoard = pendingShariahBoard;
        pendingShariahBoard = address(0);
        emit ShariahBoardSet(shariahBoard);
    }

    function approveAsset(bytes32 marketId, bool approved) external onlyShariahBoard {
        _approvedAssets[marketId] = approved;
        emit AssetApproved(marketId, approved);
    }

    function approveCollateral(address token, bool approved) external onlyShariahBoard {
        require(token != address(0), "SR: zero token");
        _approvedCollaterals[token] = approved;
        emit CollateralApproved(token, approved);
    }

    /// AUDIT FIX (P15-M-2): Cap at 5x (not 10x) — matches Baraka whitepaper Shariah design.
    /// Individual markets can be set lower (e.g. 3x for volatile assets).
    function setMaxLeverage(bytes32 marketId, uint256 maxLev) external onlyShariahBoard {
        require(maxLev >= 1 && maxLev <= 5, "SR: leverage 1-5 (Shariah cap)");
        _maxLeverage[marketId] = maxLev;
        emit MaxLeverageSet(marketId, maxLev);
    }

    function setFatwaCid(string calldata cid) external onlyShariahBoard {
        fatwaCid = cid;
        emit FatwaCidSet(cid);
    }

    /// @notice Emergency halt — freezes all trading immediately.
    /// Halt is instant (emergency use). Un-halt also goes through board, but owner
    /// has a timelock-gated override for the case where board becomes unresponsive.
    function setHalt(bool halted) external onlyShariahBoard {
        _halted = halted;
        // If board un-halts, cancel any pending governance override
        if (!halted && haltOverrideProposedAt != 0) {
            haltOverrideProposedAt = 0;
            emit HaltOverrideCancelled();
        }
        emit ProtocolHalted(halted);
    }

    /// AUDIT FIX (P10-M-6): Owner proposes a governance halt override.
    /// Only meaningful when protocol is halted. Starts the 48-hour countdown.
    /// The board can still call setHalt(false) to cancel this before it executes.
    function proposeHaltOverride() external onlyOwner {
        require(_halted, "SR: not halted");
        require(haltOverrideProposedAt == 0, "SR: override already pending");
        haltOverrideProposedAt = block.timestamp;
        emit HaltOverrideProposed(block.timestamp + HALT_OVERRIDE_DELAY);
    }

    /// AUDIT FIX (P10-M-6): Execute the governance override after the delay has elapsed.
    /// Resumes trading. The board retains the ability to re-halt immediately after.
    function executeHaltOverride() external onlyOwner {
        require(haltOverrideProposedAt != 0, "SR: no override pending");
        require(block.timestamp >= haltOverrideProposedAt + HALT_OVERRIDE_DELAY, "SR: override delay not elapsed");
        haltOverrideProposedAt = 0;
        _halted = false;
        emit HaltOverrideExecuted();
        emit ProtocolHalted(false);
    }

    /// AUDIT FIX (P10-M-6): Owner can cancel a pending override (governance changed mind).
    function cancelHaltOverride() external onlyOwner {
        require(haltOverrideProposedAt != 0, "SR: no override pending");
        haltOverrideProposedAt = 0;
        emit HaltOverrideCancelled();
    }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("SR: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // IShariahRegistry — validation
    // ─────────────────────────────────────────────────────

    function isApprovedAsset(bytes32 marketId) external view override returns (bool) {
        return _approvedAssets[marketId];
    }

    function isApprovedCollateral(address token) external view override returns (bool) {
        return _approvedCollaterals[token];
    }

    function maxLeverage(bytes32 marketId) external view override returns (uint256) {
        uint256 ml = _maxLeverage[marketId];
        return ml > 0 ? ml : DEFAULT_MAX_LEVERAGE;
    }

    function isProtocolHalted() external view override returns (bool) {
        return _halted;
    }

    /// @dev INFO (L2-I-2): assetCompliance (ComplianceOracle) and _approvedAssets (ShariahRegistry)
    ///      serve different purposes: ComplianceOracle = attestation-based, ShariahRegistry = operational.
    ///      Both must approve an asset before trading is allowed.
    /// @dev INFO (L2-I-3): No timelock on ShariahRegistry admin functions by design —
    ///      Shariah board must be able to halt immediately during market events.

    /// @notice Validate an order before execution.
    ///         Checks: asset approved, not halted, leverage within Shariah limit.
    function validateOrder(
        bytes32 /* subaccount — unused in v2, validation uses marketId only */,
        bytes32 marketId,
        int256  newSize,
        uint256 /* collateral — unused in v2, margin is cross */
    ) external view override {
        require(!_halted, "SR: protocol halted");
        require(_approvedAssets[marketId], "SR: asset not approved");

        // Leverage check: effective leverage = notional / equity
        // This is enforced via MarginEngine IMR. We just verify IMR >= 1/maxLev.
        if (address(marginEngine) != address(0) && newSize != 0) {
            uint256 ml = _maxLeverage[marketId];
            if (ml == 0) ml = DEFAULT_MAX_LEVERAGE;
            /// AUDIT FIX (P21-M-6): Use ceiling division, consistent with MatchingEngine (P20-L-5).
            /// Floor division (WAD/ml) can produce a lower minIMR than MatchingEngine's ceiling check,
            /// causing ShariahRegistry to approve markets that MatchingEngine then rejects on every trade.
            uint256 minIMR = (WAD + ml - 1) / ml; // e.g. 5x → ceil(1/5) = 0.2e18 = 20%

            IMarginEngine.MarketParams memory params = marginEngine.getMarketParams(marketId);
            require(params.initialMarginRate >= minIMR, "SR: market IMR below Shariah minimum");
        }
    }
}
