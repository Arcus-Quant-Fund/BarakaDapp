// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../interfaces/IFeeEngine.sol";
import "../interfaces/IVault.sol";
import "../interfaces/ISubaccountManager.sol";

/**
 * @title FeeEngine
 * @author Baraka Protocol v2
 * @notice Maker-taker fee model with BRKX discount tiers.
 *
 *         Base fees (no BRKX):  5.0 bps taker / 0.5 bps maker rebate
 *         Tier 1 (≥1k BRKX):   4.0 bps taker / 1.0 bps maker rebate
 *         Tier 2 (≥10k BRKX):  3.5 bps taker / 1.5 bps maker rebate
 *         Tier 3 (≥50k BRKX):  2.5 bps taker / 2.0 bps maker rebate
 *
 *         Fee split: 60% Treasury, 20% InsuranceFund, 20% Stakers
 *
 *         Uses ERC20Votes.getPastVotes() for flash-loan resistance:
 *         BRKX balance for tier lookup is from previous block.
 */
contract FeeEngine is IFeeEngine, Ownable2Step {

    uint256 constant WAD = 1e18;
    uint256 constant BPS = 1e14; // 1 basis point in WAD scale

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    IVault public immutable vault;
    address public immutable collateralToken;
    uint256 public immutable collateralScale;
    /// AUDIT FIX (P6-M-2): SubaccountManager for resolving subaccount → owner for tier lookup.
    ISubaccountManager public immutable subaccountManager;

    /// @notice BRKX governance token (ERC20Votes). Zero address = tiers disabled.
    address public brkxToken;

    // ─────────────────────────────────────────────────────
    // Fee tiers (sorted ascending by minBRKX)
    // ─────────────────────────────────────────────────────

    FeeTier[] private _tiers;

    // ─────────────────────────────────────────────────────
    // Fee split recipients
    // ─────────────────────────────────────────────────────

    address public treasury;
    address public insuranceFund;
    address public stakerPool;

    /// @notice Fee split percentages (WAD scale, must sum to WAD)
    uint256 public treasuryShare  = 0.60e18; // 60%
    uint256 public insuranceShare = 0.20e18; // 20%
    uint256 public stakerShare    = 0.20e18; // 20%

    /// @notice Authorised callers (MatchingEngine)
    mapping(address => bool) public authorised;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event TakerFeeCharged(bytes32 indexed subaccount, uint256 notional, uint256 fee);
    event MakerRebatePaid(bytes32 indexed subaccount, uint256 notional, uint256 rebate);
    event FeeSplitUpdated(uint256 treasury, uint256 insurance, uint256 staker);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _vault,
        address _collateralToken,
        address _subaccountManager
    ) Ownable(initialOwner) {
        require(_vault != address(0), "FE: zero vault");
        require(_collateralToken != address(0), "FE: zero collateral");
        require(_subaccountManager != address(0), "FE: zero SAM");

        vault = IVault(_vault);
        collateralToken = _collateralToken;
        subaccountManager = ISubaccountManager(_subaccountManager);

        uint8 dec = IERC20Metadata(_collateralToken).decimals();
        collateralScale = 10 ** (18 - dec);

        // Default tiers (ascending by minBRKX)
        _tiers.push(FeeTier({minBRKX: 0,         takerFeeBps: 5 * BPS,   makerFeeBps: BPS / 2}));     // 5.0 / 0.5
        _tiers.push(FeeTier({minBRKX: 1_000e18,  takerFeeBps: 4 * BPS,   makerFeeBps: 1 * BPS}));     // 4.0 / 1.0
        _tiers.push(FeeTier({minBRKX: 10_000e18, takerFeeBps: 35 * BPS / 10, makerFeeBps: 15 * BPS / 10})); // 3.5 / 1.5
        _tiers.push(FeeTier({minBRKX: 50_000e18, takerFeeBps: 25 * BPS / 10, makerFeeBps: 2 * BPS})); // 2.5 / 2.0
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "FE: zero address");
        authorised[caller] = status;
    }

    function setRecipients(address _treasury, address _insuranceFund, address _stakerPool) external onlyOwner {
        require(_treasury != address(0) && _insuranceFund != address(0), "FE: zero recipient");
        treasury = _treasury;
        insuranceFund = _insuranceFund;
        stakerPool = _stakerPool;
    }

    function setFeeSplit(uint256 _treasury, uint256 _insurance, uint256 _staker) external onlyOwner {
        require(_treasury + _insurance + _staker == WAD, "FE: split != 100%");
        treasuryShare = _treasury;
        insuranceShare = _insurance;
        stakerShare = _staker;
        emit FeeSplitUpdated(_treasury, _insurance, _staker);
    }

    function setBRKXToken(address _brkx) external onlyOwner {
        brkxToken = _brkx;
    }

    function setTier(uint256 index, uint256 minBRKX, uint256 takerBps, uint256 makerBps) external onlyOwner {
        require(index < _tiers.length, "FE: invalid tier");
        /// AUDIT FIX (L1B-L-1): Validate tier ordering — thresholds must be strictly increasing
        if (index > 0) {
            require(minBRKX > _tiers[index - 1].minBRKX, "FE: tier threshold not increasing");
        }
        if (index < _tiers.length - 1) {
            require(minBRKX < _tiers[index + 1].minBRKX, "FE: tier threshold not increasing");
        }
        _tiers[index] = FeeTier(minBRKX, takerBps, makerBps);
    }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("FE: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // Core — fee computation
    // ─────────────────────────────────────────────────────

    function computeTakerFee(bytes32 subaccount, uint256 notional) external view override returns (uint256) {
        FeeTier memory tier = _getTier(subaccount);
        return notional * tier.takerFeeBps / WAD;
    }

    function computeMakerRebate(bytes32 subaccount, uint256 notional) external view override returns (uint256) {
        FeeTier memory tier = _getTier(subaccount);
        return notional * tier.makerFeeBps / WAD;
    }

    // ─────────────────────────────────────────────────────
    // Core — fee charging (called by MatchingEngine)
    // ─────────────────────────────────────────────────────

    function chargeTakerFee(bytes32 subaccount, uint256 notional) external override returns (uint256 fee) {
        require(authorised[msg.sender], "FE: not authorised");

        FeeTier memory tier = _getTier(subaccount);
        fee = notional * tier.takerFeeBps / WAD;
        if (fee == 0) return 0;

        // Convert from WAD to token decimals
        uint256 feeTokens = fee / collateralScale;
        if (feeTokens == 0) return 0;

        // Split fee to recipients
        uint256 toTreasury  = feeTokens * treasuryShare / WAD;
        uint256 toInsurance  = feeTokens * insuranceShare / WAD;
        uint256 toStakers    = feeTokens - toTreasury - toInsurance; // remainder avoids rounding loss

        if (toTreasury > 0 && treasury != address(0)) {
            vault.chargeFee(subaccount, collateralToken, toTreasury, treasury);
        }
        if (toInsurance > 0 && insuranceFund != address(0)) {
            vault.chargeFee(subaccount, collateralToken, toInsurance, insuranceFund);
        }
        if (toStakers > 0) {
            /// AUDIT FIX (L1B-M-5): If stakerPool is zero, redirect to treasury instead of locking
            address stakeRecipient = stakerPool != address(0) ? stakerPool : treasury;
            if (stakeRecipient != address(0)) {
                vault.chargeFee(subaccount, collateralToken, toStakers, stakeRecipient);
            }
        }

        emit TakerFeeCharged(subaccount, notional, fee);
    }

    /// @dev DEPRECATED — use processTradeFees() instead. Kept for interface compliance.
    /// AUDIT FIX (L1B-H-3): This function created unbacked phantom balance.
    /// Now reverts to force callers to use processTradeFees().
    function payMakerRebate(bytes32 /* subaccount */, uint256 /* notional */) external pure override returns (uint256) {
        revert("FE: use processTradeFees()");
    }

    /// @notice Process trade fees atomically: charge taker fee, pay maker rebate from collected fees.
    /// AUDIT FIX (L1B-H-3): Maker rebate funded from taker fee via vault.transferInternal
    /// (no phantom balance creation — real tokens back every credit).
    function processTradeFees(
        bytes32 takerSubaccount,
        bytes32 makerSubaccount,
        uint256 notional
    ) external override {
        require(authorised[msg.sender], "FE: not authorised");

        FeeTier memory tier = _getTier(takerSubaccount);
        uint256 takerFee = notional * tier.takerFeeBps / WAD;
        uint256 makerRebate = notional * tier.makerFeeBps / WAD;

        if (takerFee == 0) return;

        uint256 takerFeeTokens = takerFee / collateralScale;
        uint256 makerRebateTokens = makerRebate / collateralScale;
        if (takerFeeTokens == 0) return;

        /// AUDIT FIX (L1B-M-3): Cap fees at taker's available balance — prevents DOS on trading
        uint256 takerBal = vault.balance(takerSubaccount, collateralToken);
        if (takerFeeTokens > takerBal) {
            takerFeeTokens = takerBal;
            // Proportionally reduce maker rebate
            if (takerFeeTokens == 0) return;
            makerRebateTokens = makerRebateTokens * takerFeeTokens / (takerFee / collateralScale);
        }

        // Cap rebate at taker fee — can never rebate more than collected
        if (makerRebateTokens > takerFeeTokens) makerRebateTokens = takerFeeTokens;

        // 1. Transfer maker rebate from taker → maker (internal, no phantom balance)
        if (makerRebateTokens > 0) {
            vault.transferInternal(takerSubaccount, makerSubaccount, collateralToken, makerRebateTokens);
            emit MakerRebatePaid(makerSubaccount, notional, makerRebate);
        }

        // 2. Split remaining fee (takerFee - makerRebate) to treasury/insurance/stakers
        uint256 remainingFee = takerFeeTokens - makerRebateTokens;
        if (remainingFee > 0) {
            uint256 toTreasury  = remainingFee * treasuryShare / WAD;
            uint256 toInsurance  = remainingFee * insuranceShare / WAD;
            uint256 toStakers    = remainingFee - toTreasury - toInsurance;

            if (toTreasury > 0 && treasury != address(0)) {
                vault.chargeFee(takerSubaccount, collateralToken, toTreasury, treasury);
            }
            if (toInsurance > 0 && insuranceFund != address(0)) {
                vault.chargeFee(takerSubaccount, collateralToken, toInsurance, insuranceFund);
            }
            if (toStakers > 0) {
                /// AUDIT FIX (L1B-M-5): If stakerPool is zero, redirect to treasury
                address stakeRecipient = stakerPool != address(0) ? stakerPool : treasury;
                if (stakeRecipient != address(0)) {
                    vault.chargeFee(takerSubaccount, collateralToken, toStakers, stakeRecipient);
                }
            }
        }

        emit TakerFeeCharged(takerSubaccount, notional, takerFee);
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    function getTierCount() external view returns (uint256) {
        return _tiers.length;
    }

    function getTier(uint256 index) external view returns (FeeTier memory) {
        return _tiers[index];
    }

    // ─────────────────────────────────────────────────────
    // Internal — tier lookup
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P6-M-2): Implement BRKX tier lookup using ERC20Votes.getPastVotes().
    /// Uses previous block's voting power for flash-loan resistance (cannot inflate BRKX
    /// balance in same block to get fee discount, then dump).
    /// @dev INFO (L1B-I-1): Three separate vault.chargeFee calls in chargeTakerFee/processTradeFees
    ///      are intentional — each recipient gets an explicit transfer for auditability.
    function _getTier(bytes32 subaccount) internal view returns (FeeTier memory) {
        // If BRKX token not set, return base tier
        if (brkxToken == address(0)) {
            return _tiers[0];
        }

        // Resolve subaccount → owner
        address owner = subaccountManager.getOwner(subaccount);
        if (owner == address(0)) return _tiers[0];

        // Flash-loan resistant: use previous block's voting power
        // On block 0 (genesis), fallback to base tier
        if (block.number == 0) return _tiers[0];

        uint256 votes = IVotes(brkxToken).getPastVotes(owner, block.number - 1);
        if (votes == 0) return _tiers[0];

        // Iterate tiers descending — return highest qualifying tier
        for (uint256 i = _tiers.length; i > 0; i--) {
            if (votes >= _tiers[i - 1].minBRKX) {
                return _tiers[i - 1];
            }
        }

        return _tiers[0];
    }
}
