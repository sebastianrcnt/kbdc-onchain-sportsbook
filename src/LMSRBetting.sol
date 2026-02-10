// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";

contract LMSRBetting {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant LN_2_WAD = 693147180559945309;
    uint256 private constant MAX_EXP_INPUT_WAD = 135e18;

    struct Market {
        string title;
        uint64 closeTime;
        uint256 b;
        uint256 qYes;
        uint256 qNo;
        uint256 pool;
        bool resolved;
        uint8 winningOutcome;
        address creator;
    }

    error Unauthorized();
    error InvalidMarket();
    error InvalidOutcome();
    error InvalidCloseTime();
    error InvalidLiquidity();
    error InvalidShares();
    error InvalidFeeBps();
    error ZeroAddress();
    error MarketClosed();
    error MarketStillOpen();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error InsufficientFunding(uint256 required, uint256 provided);
    error SlippageExceeded(uint256 limit, uint256 actual);
    error InsufficientMsgValue(uint256 required, uint256 provided);
    error InsufficientUserShares(uint256 available, uint256 requested);
    error InsufficientMarketDepth(uint256 available, uint256 requested);
    error TransferFailed();
    error ExpInputTooLarge();
    error NoClaimableShares();
    error Reentrancy();

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event FeeConfigUpdated(uint256 feeBps, address indexed feeRecipient);
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string title,
        uint64 closeTime,
        uint256 b,
        uint256 initialFunding
    );
    event Bought(
        uint256 indexed marketId,
        address indexed buyer,
        uint8 indexed outcome,
        uint256 shares,
        uint256 cost,
        uint256 fee,
        uint256 maxCost
    );
    event Sold(
        uint256 indexed marketId,
        address indexed seller,
        uint8 indexed outcome,
        uint256 shares,
        uint256 payout,
        uint256 userPayout,
        uint256 fee,
        uint256 minPayout
    );
    event Resolved(uint256 indexed marketId, uint8 winningOutcome);
    event Claimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 payout
    );

    Market[] private markets;
    mapping(uint256 => mapping(address => uint256[2])) public userShares;

    address public owner;
    uint256 public feeBps;
    address public feeRecipient;

    uint256 private unlocked = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (unlocked != 1) revert Reentrancy();
        unlocked = 2;
        _;
        unlocked = 1;
    }

    constructor(
        address initialOwner,
        address initialFeeRecipient,
        uint256 initialFeeBps
    ) {
        if (initialOwner == address(0) || initialFeeRecipient == address(0))
            revert ZeroAddress();
        if (initialFeeBps > BPS_DENOMINATOR) revert InvalidFeeBps();

        owner = initialOwner;
        feeRecipient = initialFeeRecipient;
        feeBps = initialFeeBps;

        emit OwnershipTransferred(address(0), initialOwner);
        emit FeeConfigUpdated(initialFeeBps, initialFeeRecipient);
    }

    // transfer ownership of root contract
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function setFeeConfig(
        uint256 newFeeBps,
        address newFeeRecipient
    ) external onlyOwner {
        // fee unit under denomiator? revert
        if (newFeeBps > BPS_DENOMINATOR) revert InvalidFeeBps();

        // prevent burn
        if (newFeeRecipient == address(0)) revert ZeroAddress();

        feeBps = newFeeBps;
        feeRecipient = newFeeRecipient;

        emit FeeConfigUpdated(newFeeBps, newFeeRecipient);
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function requiredSubsidy(uint256 b) public pure returns (uint256) {
        if (b == 0) revert InvalidLiquidity();

        // (b * ln(2)) / WAD
        return FixedPointMathLib.fullMulDivUp(b, LN_2_WAD, WAD);
    }

    function createMarket(
        string calldata title,
        uint64 closeTime,
        uint256 b
    ) external payable returns (uint256 marketId) {
        if (closeTime <= block.timestamp) revert InvalidCloseTime();

        uint256 minimumFunding = requiredSubsidy(b);
        if (msg.value < minimumFunding) {
            revert InsufficientFunding(minimumFunding, msg.value);
        }

        marketId = markets.length;
        markets.push(
            Market({
                title: title,
                closeTime: closeTime,
                b: b,
                qYes: 0,
                qNo: 0,
                pool: msg.value,
                resolved: false,
                winningOutcome: 0,
                creator: msg.sender
            })
        );

        emit MarketCreated(
            marketId,
            msg.sender,
            title,
            closeTime,
            b,
            msg.value
        );
    }

    // query how much money paid for buying a unit share in market
    // outcome: 0 for yes, 1 for no
    function quoteBuyCost(
        uint256 marketId,
        uint8 outcome,
        uint256 shares
    ) public view returns (uint256) {
        if (shares == 0) revert InvalidShares();
        _assertOutcome(outcome);

        Market storage market = _getMarket(marketId);
        return _quoteBuyCost(market, outcome, shares);
    }

    // query how much money paid for selling a unit share in market
    // outcome: 0 for yes, 1 for no
    function quoteSellPayout(
        uint256 marketId,
        uint8 outcome,
        uint256 shares
    ) public view returns (uint256) {
        if (shares == 0) revert InvalidShares();
        _assertOutcome(outcome);

        Market storage market = _getMarket(marketId);
        return _quoteSellPayout(market, outcome, shares);
    }

    // buy shares in market, safeguarded by maxCost
    function buy(
        uint256 marketId,
        uint8 outcome,
        uint256 shares,
        uint256 maxCost
    ) external payable nonReentrant {
        if (shares == 0) revert InvalidShares();
        _assertOutcome(outcome);

        Market storage market = _getMarket(marketId);
        _assertTradable(market);

        uint256 cost = _quoteBuyCost(market, outcome, shares);
        if (cost > maxCost) revert SlippageExceeded(maxCost, cost);

        uint256 fee = _feeOf(cost);
        uint256 requiredValue = cost + fee;
        if (msg.value < requiredValue) {
            revert InsufficientMsgValue(requiredValue, msg.value);
        }

        if (outcome == 0) {
            market.qYes += shares;
        } else {
            market.qNo += shares;
        }
        market.pool += cost;
        userShares[marketId][msg.sender][outcome] += shares;

        _sendEth(feeRecipient, fee);

        if (msg.value > requiredValue) {
            _sendEth(msg.sender, msg.value - requiredValue);
        }

        emit Bought(marketId, msg.sender, outcome, shares, cost, fee, maxCost);
    }

    function sell(
        uint256 marketId,
        uint8 outcome,
        uint256 shares,
        uint256 minPayout
    ) external nonReentrant {
        if (shares == 0) revert InvalidShares();
        _assertOutcome(outcome);

        Market storage market = _getMarket(marketId);
        _assertTradable(market);

        uint256 available = userShares[marketId][msg.sender][outcome];
        if (available < shares)
            revert InsufficientUserShares(available, shares);

        uint256 payout = _quoteSellPayout(market, outcome, shares);
        if (payout < minPayout) revert SlippageExceeded(minPayout, payout);

        uint256 fee = _feeOf(payout);
        uint256 userPayout = payout - fee;

        userShares[marketId][msg.sender][outcome] = available - shares;

        if (outcome == 0) {
            market.qYes -= shares;
        } else {
            market.qNo -= shares;
        }

        market.pool -= payout;

        _sendEth(msg.sender, userPayout);
        _sendEth(feeRecipient, fee);

        emit Sold(
            marketId,
            msg.sender,
            outcome,
            shares,
            payout,
            userPayout,
            fee,
            minPayout
        );
    }

    // only oracle can resolve?
    function resolve(
        uint256 marketId,
        uint8 winningOutcome
    ) external onlyOwner {
        _assertOutcome(winningOutcome);

        Market storage market = _getMarket(marketId);
        if (market.resolved) revert MarketAlreadyResolved();
        if (block.timestamp < market.closeTime) revert MarketStillOpen();

        market.resolved = true;
        market.winningOutcome = winningOutcome;

        emit Resolved(marketId, winningOutcome);
    }

    function claim(uint256 marketId) external nonReentrant {
        Market storage market = _getMarket(marketId);
        if (!market.resolved) revert MarketNotResolved();

        uint8 winningOutcome = market.winningOutcome;
        uint256 payout = userShares[marketId][msg.sender][winningOutcome];
        if (payout == 0) revert NoClaimableShares();

        userShares[marketId][msg.sender][winningOutcome] = 0;
        market.pool -= payout;

        _sendEth(msg.sender, payout);

        emit Claimed(marketId, msg.sender, payout);
    }

    function getMarket(
        uint256 marketId
    )
        external
        view
        returns (
            string memory title,
            uint64 closeTime,
            uint256 b,
            uint256 qYes,
            uint256 qNo,
            uint256 pool,
            bool resolved,
            uint8 winningOutcome,
            address creator
        )
    {
        Market storage market = _getMarket(marketId);

        title = market.title;
        closeTime = market.closeTime;
        b = market.b;
        qYes = market.qYes;
        qNo = market.qNo;
        pool = market.pool;
        resolved = market.resolved;
        winningOutcome = market.winningOutcome;
        creator = market.creator;
    }

    function getPriceWad(
        uint256 marketId
    ) external view returns (uint256 yesPriceWad, uint256 noPriceWad) {
        Market storage market = _getMarket(marketId);
        return _priceWad(market.qYes, market.qNo, market.b);
    }

    function getUserShares(
        uint256 marketId,
        address user
    ) external view returns (uint256 yesShares, uint256 noShares) {
        _getMarket(marketId);
        uint256[2] storage shares = userShares[marketId][user];
        yesShares = shares[0];
        noShares = shares[1];
    }

    function _quoteBuyCost(
        Market storage market,
        uint8 outcome,
        uint256 shares
    ) internal view returns (uint256) {
        uint256 oldCost = _cost(market.qYes, market.qNo, market.b);

        uint256 newQYes = market.qYes;
        uint256 newQNo = market.qNo;

        if (outcome == 0) {
            newQYes += shares;
        } else {
            newQNo += shares;
        }

        _assertExpInput(newQYes, market.b);
        _assertExpInput(newQNo, market.b);

        uint256 newCost = _cost(newQYes, newQNo, market.b);
        return newCost - oldCost;
    }

    function _quoteSellPayout(
        Market storage market,
        uint8 outcome,
        uint256 shares
    ) internal view returns (uint256) {
        uint256 oldCost = _cost(market.qYes, market.qNo, market.b);

        uint256 newQYes = market.qYes;
        uint256 newQNo = market.qNo;

        if (outcome == 0) {
            if (newQYes < shares)
                revert InsufficientMarketDepth(newQYes, shares);
            newQYes -= shares;
        } else {
            if (newQNo < shares) revert InsufficientMarketDepth(newQNo, shares);
            newQNo -= shares;
        }

        uint256 newCost = _cost(newQYes, newQNo, market.b);
        return oldCost - newCost;
    }

    function _cost(
        uint256 qYes,
        uint256 qNo,
        uint256 b
    ) internal pure returns (uint256) {
        _assertExpInput(qYes, b);
        _assertExpInput(qNo, b);

        int256 x = int256(FixedPointMathLib.fullMulDiv(qYes, WAD, b));
        int256 y = int256(FixedPointMathLib.fullMulDiv(qNo, WAD, b));

        int256 expX = FixedPointMathLib.expWad(x);
        int256 expY = FixedPointMathLib.expWad(y);

        int256 lnSum = FixedPointMathLib.lnWad(expX + expY);
        return FixedPointMathLib.fullMulDiv(b, uint256(lnSum), WAD);
    }

    function _priceWad(
        uint256 qYes,
        uint256 qNo,
        uint256 b
    ) internal pure returns (uint256 yesPriceWad, uint256 noPriceWad) {
        _assertExpInput(qYes, b);
        _assertExpInput(qNo, b);

        int256 x = int256(FixedPointMathLib.fullMulDiv(qYes, WAD, b));
        int256 y = int256(FixedPointMathLib.fullMulDiv(qNo, WAD, b));

        int256 expX = FixedPointMathLib.expWad(x);
        int256 expY = FixedPointMathLib.expWad(y);

        uint256 expSum = uint256(expX + expY);
        yesPriceWad = FixedPointMathLib.fullMulDiv(uint256(expX), WAD, expSum);
        noPriceWad = WAD - yesPriceWad;
    }

    function _feeOf(uint256 grossAmount) internal view returns (uint256) {
        return
            FixedPointMathLib.fullMulDiv(grossAmount, feeBps, BPS_DENOMINATOR);
    }

    function _assertTradable(Market storage market) internal view {
        if (market.resolved || block.timestamp >= market.closeTime)
            revert MarketClosed();
    }

    function _assertOutcome(uint8 outcome) internal pure {
        if (outcome > 1) revert InvalidOutcome();
    }

    function _assertExpInput(uint256 q, uint256 b) internal pure {
        uint256 input = FixedPointMathLib.fullMulDiv(q, WAD, b);
        if (input > MAX_EXP_INPUT_WAD) revert ExpInputTooLarge();
    }

    function _getMarket(
        uint256 marketId
    ) internal view returns (Market storage market) {
        if (marketId >= markets.length) revert InvalidMarket();
        market = markets[marketId];
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
