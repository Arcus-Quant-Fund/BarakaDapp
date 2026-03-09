// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IEverlastingOption.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title PerpetualSukuk
 * @author Baraka Protocol v2
 * @notice On-chain sukuk with embedded everlasting call option.
 *
 *         Ported from v1. Key change: uses bytes32 marketId for asset reference.
 *         All audit fixes preserved (PS-H-1/2/3, M-PS1, I-7, L-10, etc.)
 *
 *         Structure: issue -> subscribe -> claimProfit -> redeem (at maturity)
 *         AAOIFI Shariah Standard No. 17
 */
contract PerpetualSukuk is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant SECS_PER_YEAR = 365 days;

    IEverlastingOption public immutable evOption;
    IOracleAdapter     public immutable oracle;

    uint256 private _nextId;

    struct SukukInfo {
        address issuer;
        bytes32 asset;          // v2: bytes32 marketId
        address token;
        uint256 parValue;
        uint256 profitRateWad;
        uint256 maturityEpoch;
        uint256 issuedAt;
        uint256 totalSubscribed;
        bool    redeemed;
        /// AUDIT FIX (P3-INST-15): Store USD-denominated call strike at issuance.
        /// Previously, parValueWad was computed by normalizing token decimals → WAD, which
        /// gives a strike of 1e18 = $1 for WETH-denominated sukuk (deep ITM for BTC/ETH assets).
        /// The correct strike is the USD value of the par at issuance: parValue × spotUSD / tokenScale.
        uint256 callStrikeWad;
    }

    struct Subscription {
        uint256 amount;
        uint256 lastProfitAt;
        bool    redeemed;
    }

    mapping(uint256 => SukukInfo) public sukuks;
    mapping(uint256 => mapping(address => Subscription)) public subscriptions;
    mapping(uint256 => uint256) private _issuerReserve;
    mapping(uint256 => uint256) private _investorPrincipal;

    event SukukIssued(uint256 indexed id, address indexed issuer, bytes32 asset, address token, uint256 par, uint256 profitRateWad, uint256 maturityEpoch);
    event Subscribed(uint256 indexed id, address indexed investor, uint256 amount);
    event ProfitClaimed(uint256 indexed id, address indexed investor, uint256 profit);
    event Redeemed(uint256 indexed id, address indexed investor, uint256 principal, uint256 callUpside);

    constructor(address initialOwner, address _evOption, address _oracle) Ownable(initialOwner) {
        require(_evOption != address(0), "PS: zero evOption");
        require(_oracle != address(0), "PS: zero oracle");
        evOption = IEverlastingOption(_evOption);
        oracle = IOracleAdapter(_oracle);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("PS: renounce disabled");
    }

    function issue(
        bytes32 asset,
        address token,
        uint256 parValue,
        uint256 profitRateWad,
        uint256 maturityEpoch
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        require(token != address(0), "PS: zero addr");
        require(parValue > 0, "PS: zero par");
        require(profitRateWad > 0 && profitRateWad < WAD, "PS: bad rate");
        require(maturityEpoch > block.timestamp, "PS: past maturity");

        id = _nextId++;

        /// AUDIT FIX (P3-INST-15): Compute USD call strike at issuance using oracle.
        /// parValueWad was previously `parValue * 10^(18-dec)` which gives a strike in token units,
        /// not USD. For WETH (18dec), parValue=1e18 → parValueWad=1e18=$1, deeply ITM at ETH=$3k.
        /// Correct: USD value = parValue * spotUSD / tokenScale.
        uint256 spotUsd = oracle.getIndexPrice(asset);
        require(spotUsd > 0, "PS: oracle not set");
        uint8 tokenDec_ = IERC20Metadata(token).decimals();
        require(tokenDec_ <= 18, "PS: decimals > 18");
        uint256 callStrikeWad_ = (parValue * spotUsd) / (10 ** uint256(tokenDec_));

        sukuks[id] = SukukInfo({
            issuer: msg.sender,
            asset: asset,
            token: token,
            parValue: parValue,
            profitRateWad: profitRateWad,
            maturityEpoch: maturityEpoch,
            issuedAt: block.timestamp,
            totalSubscribed: 0,
            redeemed: false,
            callStrikeWad: callStrikeWad_
        });

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), parValue);
        require(IERC20(token).balanceOf(address(this)) - balBefore == parValue, "PS: fee-on-transfer not supported");

        _issuerReserve[id] = parValue;
        emit SukukIssued(id, msg.sender, asset, token, parValue, profitRateWad, maturityEpoch);
    }

    function subscribe(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        SukukInfo storage s = sukuks[id];
        require(!s.redeemed, "PS: redeemed");
        require(block.timestamp < s.maturityEpoch, "PS: matured");
        require(amount > 0, "PS: zero amount");
        require(s.totalSubscribed + amount <= s.parValue, "PS: over capacity");

        s.totalSubscribed += amount;

        Subscription storage sub = subscriptions[id][msg.sender];
        // PS-H-1 fix: auto-claim before resetting lastProfitAt
        if (sub.amount > 0 && sub.lastProfitAt > 0) {
            uint256 elapsed = block.timestamp - sub.lastProfitAt;
            /// AUDIT FIX (P15-M-10): round up so small positions never truncate to zero coupon
            /// AUDIT FIX (P16-AR-H2): Nested mulDiv prevents sub.amount * profitRateWad overflow
            uint256 profit = Math.mulDiv(
                Math.mulDiv(sub.amount, s.profitRateWad, WAD),
                elapsed,
                SECS_PER_YEAR,
                Math.Rounding.Ceil
            );
            uint256 avail = _issuerReserve[id];
            if (profit > avail) profit = avail;
            if (profit > 0) {
                _issuerReserve[id] -= profit;
                IERC20(s.token).safeTransfer(msg.sender, profit);
                emit ProfitClaimed(id, msg.sender, profit);
            }
        }
        sub.amount += amount;
        sub.lastProfitAt = block.timestamp;

        uint256 balBefore = IERC20(s.token).balanceOf(address(this));
        IERC20(s.token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(s.token).balanceOf(address(this)) - balBefore == amount, "PS: fee-on-transfer not supported");

        _investorPrincipal[id] += amount;
        emit Subscribed(id, msg.sender, amount);
    }

    function claimProfit(uint256 id) external nonReentrant whenNotPaused {
        SukukInfo storage s = sukuks[id];
        Subscription storage sub = subscriptions[id][msg.sender];
        if (sub.amount == 0 || sub.redeemed) return;

        uint256 elapsed = block.timestamp - sub.lastProfitAt;
        /// AUDIT FIX (P15-M-10): round up so small positions never truncate to zero coupon
        /// AUDIT FIX (P16-AR-H2): Nested mulDiv prevents sub.amount * profitRateWad overflow
        uint256 profit = Math.mulDiv(
            Math.mulDiv(sub.amount, s.profitRateWad, WAD),
            elapsed,
            SECS_PER_YEAR,
            Math.Rounding.Ceil
        );
        if (profit == 0) return;

        uint256 available = _issuerReserve[id];
        if (profit > available) profit = available;

        sub.lastProfitAt = block.timestamp; // I-7 fix: always advance clock

        if (profit == 0) return;
        _issuerReserve[id] -= profit;
        IERC20(s.token).safeTransfer(msg.sender, profit);
        emit ProfitClaimed(id, msg.sender, profit);
    }

    function redeem(uint256 id) external nonReentrant whenNotPaused {
        SukukInfo storage s = sukuks[id];
        Subscription storage sub = subscriptions[id][msg.sender];
        require(block.timestamp >= s.maturityEpoch, "PS: not matured");
        require(sub.amount > 0, "PS: not subscribed");
        require(!sub.redeemed, "PS: already redeemed");

        // PS-M-4 fix: auto-claim accrued profit
        {
            uint256 elapsed = block.timestamp - sub.lastProfitAt;
            /// AUDIT FIX (P15-M-10): round up so small positions never truncate to zero coupon
            /// AUDIT FIX (P16-AR-H2): Nested mulDiv prevents sub.amount * profitRateWad overflow
            uint256 profit = Math.mulDiv(
                Math.mulDiv(sub.amount, s.profitRateWad, WAD),
                elapsed,
                SECS_PER_YEAR,
                Math.Rounding.Ceil
            );
            uint256 avail = _issuerReserve[id];
            if (profit > avail) profit = avail;
            if (profit > 0) {
                sub.lastProfitAt = block.timestamp;
                _issuerReserve[id] -= profit;
                IERC20(s.token).safeTransfer(msg.sender, profit);
                emit ProfitClaimed(id, msg.sender, profit);
            }
        }

        sub.redeemed = true;
        uint256 principal = sub.amount;

        require(_investorPrincipal[id] >= principal, "PS: principal reserve depleted");
        _investorPrincipal[id] -= principal;
        IERC20(s.token).safeTransfer(msg.sender, principal);

        // L-10 fix
        if (_investorPrincipal[id] == 0) {
            sukuks[id].redeemed = true;
        }

        // Embedded call upside
        /// AUDIT FIX (P5-M-9): Oracle staleness check — a stale high price inflates the
        /// embedded call option value, overpaying from issuer reserve.
        require(!oracle.isStale(s.asset), "PS: oracle stale");
        uint256 spotWad = oracle.getIndexPrice(s.asset);
        /// AUDIT FIX (P3-INST-15): Use USD-denominated callStrikeWad stored at issuance (not token-decimal normalized).
        uint256 callRateWad = evOption.quoteCall(s.asset, spotWad, s.callStrikeWad);
        uint256 callUpside = (callRateWad * principal) / WAD;

        uint256 issuerAvail = _issuerReserve[id];
        uint256 actualCall = callUpside > issuerAvail ? issuerAvail : callUpside;
        if (actualCall > 0) {
            _issuerReserve[id] -= actualCall;
            IERC20(s.token).safeTransfer(msg.sender, actualCall);
        }

        emit Redeemed(id, msg.sender, principal, actualCall);
    }

    /// AUDIT FIX (P16-UP-H5): Emergency token recovery when contract is paused
    function emergencyRecoverTokens(address token, address to, uint256 amount) external onlyOwner whenPaused {
        require(to != address(0), "PS: zero recipient");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRecovery(token, to, amount);
    }
    event EmergencyRecovery(address indexed token, address indexed to, uint256 amount);

    /// AUDIT FIX (PS-M-1): Allow issuer to top up reserve for profit distribution + call upside
    function topUpReserve(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        SukukInfo storage s = sukuks[id];
        require(msg.sender == s.issuer, "PS: not issuer");
        require(!s.redeemed, "PS: fully redeemed");
        require(amount > 0, "PS: zero amount");

        uint256 balBefore = IERC20(s.token).balanceOf(address(this));
        IERC20(s.token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(s.token).balanceOf(address(this)) - balBefore == amount, "PS: fee-on-transfer not supported");

        _issuerReserve[id] += amount;
    }

    function getEmbeddedCallValue(uint256 id, address investor)
        external view returns (uint256 callRateWad, uint256 callUpside)
    {
        SukukInfo storage s = sukuks[id];
        Subscription storage sub = subscriptions[id][investor];
        uint256 spotWad = oracle.getIndexPrice(s.asset);
        /// AUDIT FIX (P3-INST-15): Use stored USD callStrikeWad (set at issuance) — not token-decimal normalized.
        callRateWad = evOption.quoteCall(s.asset, spotWad, s.callStrikeWad);
        callUpside = (callRateWad * sub.amount) / WAD;
    }

    function getAccruedProfit(uint256 id, address investor) external view returns (uint256 accrued) {
        SukukInfo storage s = sukuks[id];
        Subscription storage sub = subscriptions[id][investor];
        if (sub.amount == 0 || sub.redeemed) return 0;
        uint256 elapsed = block.timestamp - sub.lastProfitAt;
        /// AUDIT FIX (P15-M-10): round up so small positions never truncate to zero coupon
        /// AUDIT FIX (P16-AR-H2): Nested mulDiv prevents sub.amount * profitRateWad overflow
        accrued = Math.mulDiv(
            Math.mulDiv(sub.amount, s.profitRateWad, WAD),
            elapsed,
            SECS_PER_YEAR,
            Math.Rounding.Ceil
        );
        if (accrued > _issuerReserve[id]) accrued = _issuerReserve[id];
    }

    /// AUDIT FIX (P5-M-11): Allow issuer to withdraw residual reserve after full redemption.
    /// Previously, after all investors redeemed, remaining _issuerReserve was permanently locked
    /// because no function could transfer it out.
    function withdrawResidual(uint256 id) external nonReentrant whenNotPaused {
        SukukInfo storage s = sukuks[id];
        require(msg.sender == s.issuer, "PS: not issuer");
        require(s.redeemed, "PS: not fully redeemed");
        uint256 residual = _issuerReserve[id];
        require(residual > 0, "PS: no residual");
        _issuerReserve[id] = 0;
        IERC20(s.token).safeTransfer(s.issuer, residual);
    }

    function issuerReserve(uint256 id) external view returns (uint256) { return _issuerReserve[id]; }
    function investorPrincipal(uint256 id) external view returns (uint256) { return _investorPrincipal[id]; }
    function nextId() external view returns (uint256) { return _nextId; }
}
