// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";
import {Ownable} from "./utils/Ownable.sol";

// lmsr market factory가 있고 여기서 마켓을 만들 수 있음.
// 이 마켓 팩토리는 ERC-20 토큰을 용하여 마켓 운영 가능.
// 마켓은 마켓 팩토리에서 생성되며, 마켓별로 수수료를 설정할 수 있음.
// Initial Funding은 ERC-20 토큰으로 받으며, 최소수량 만큼 예치해야 함.

contract LMSRBettingV2Factory is Ownable {
    // [State]
    address[] public markets;

    // [Events]
    event MarketCreated(
        address indexed market,
        string name,
        address indexed owner,
        address indexed currency,
        uint256 liquidity
    );

    // [Constructor]
    constructor(address _owner) Ownable(_owner) {}

    // [View]
    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function getMarket(uint256 index) external view returns (address) {
        require(index < markets.length, "invalid index");
        return markets[index];
    }

    function getAllMarkets() external view returns (address[] memory) {
        return markets;
    }

    // [Factory]
    function createMarket(
        string memory name,
        address marketOwner,
        address currency,
        uint256 liquidity
    ) external returns (address market) {
        LMSRBettingV2Market newMarket = new LMSRBettingV2Market(
            name,
            marketOwner,
            currency,
            liquidity
        );

        market = address(newMarket);
        markets.push(market);

        emit MarketCreated(market, name, marketOwner, currency, liquidity);
    }
}

contract LMSRBettingV2Market is Ownable {
    // [Variables]
    string public name;
    uint256 public qYes;
    uint256 public qNo;
    uint256 public pool;

    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;

    // contract address of ERC-20 currency
    address public currency;

    // resolved?
    bool public resolved;

    // [Immutables]
    uint256 public immutable liquidity;

    // [Constants]
    uint256 private constant LN_2_WAD = 693147180559945309;
    uint256 private constant MAX_EXP_INPUT_WAD = 135e18;
    uint256 private constant WAD = 1e18;

    // [Events]
    event Bought(
        address indexed buyer,
        bool indexed outcome,
        uint256 shares,
        uint256 cost
    );

    event Sold(
        address indexed seller,
        bool indexed outcome,
        uint256 shares,
        uint256 cost
    );

    event Funded(address indexed funder, uint256 amount);

    event Resolved(bool indexed outcome);

    event Withdrawn(address indexed recipient, uint256 amount);

    // [Constructor]
    constructor(
        string memory _name,
        address _owner,
        address _currency,
        uint256 _liquidity
    ) Ownable(_owner) {
        // [Name]
        name = _name;

        // [Owner - additional validation]
        require(_isWallet(_owner), "owner is not a wallet");

        // [Currency]
        // require for currency to be nonzero
        require(_currency != address(0), "invalid currency");
        // require for currency to be a contract
        require(!_isWallet(_currency), "invalid currency");
        // note: impossible to check if a contract is a valid ERC-20 token. should rely on authority.
        currency = _currency;

        // [Resolved]
        resolved = false;

        // [LiquidityCheck]
        require(_liquidity > 0, "invalid liquidity");
        liquidity = _liquidity;
    }

    function _isWallet(address _user) internal view returns (bool) {
        return _user.code.length == 0;
    }

    // [Helpers]
    function initialFunding() public view returns (uint256) {
        require(liquidity > 0, "invalid liquidity");
        return FixedPointMathLib.fullMulDivUp(liquidity, WAD, LN_2_WAD);
    }

    function funded() public view returns (bool) {
        return IERC20(currency).balanceOf(address(this)) >= initialFunding();
    }

    function _assertExpInput(uint256 q, uint256 b) internal pure {
        uint256 input = FixedPointMathLib.fullMulDiv(q, WAD, b);
        require(input <= MAX_EXP_INPUT_WAD, "exp input too large");
    }

    function _cost(
        uint256 _qYes,
        uint256 _qNo,
        uint256 _liquidity
    ) internal pure returns (uint256) {
        _assertExpInput(_qYes, _liquidity);
        _assertExpInput(_qNo, _liquidity);

        int256 x = int256(FixedPointMathLib.fullMulDiv(_qYes, WAD, _liquidity));
        int256 y = int256(FixedPointMathLib.fullMulDiv(_qNo, WAD, _liquidity));

        int256 expX = FixedPointMathLib.expWad(x);
        int256 expY = FixedPointMathLib.expWad(y);

        int256 lnSum = FixedPointMathLib.lnWad(expX + expY);
        return FixedPointMathLib.fullMulDiv(_liquidity, uint256(lnSum), WAD);
    }

    function _quoteBuyCost(
        bool outcome,
        uint256 shares
    ) internal view returns (uint256) {
        uint256 oldCost = _cost(qYes, qNo, liquidity);
        uint256 newQYes = qYes;
        uint256 newQNo = qNo;

        if (outcome) {
            newQYes += shares;
        } else {
            newQNo += shares;
        }

        _assertExpInput(newQYes, liquidity);
        _assertExpInput(newQNo, liquidity);

        uint256 newCost = _cost(newQYes, newQNo, liquidity);
        return newCost - oldCost;
    }

    function _quoteSellPayout(
        bool outcome,
        uint256 shares
    ) internal view returns (uint256) {
        uint256 oldCost = _cost(qYes, qNo, liquidity);
        uint256 newQYes = qYes;
        uint256 newQNo = qNo;

        if (outcome) {
            require(newQYes >= shares, "insufficient market depth");
            newQYes -= shares;
        } else {
            require(newQNo >= shares, "insufficient market depth");
            newQNo -= shares;
        }

        uint256 newCost = _cost(newQYes, newQNo, liquidity);
        return oldCost - newCost;
    }

    // [Query]
    function quoteBuyCost(
        bool outcome,
        uint256 shares
    ) public view returns (uint256) {
        require(shares > 0, "invalid shares");
        return _quoteBuyCost(outcome, shares);
    }

    function quoteSellPayout(
        bool outcome,
        uint256 shares
    ) public view returns (uint256) {
        require(shares > 0, "invalid shares");
        return _quoteSellPayout(outcome, shares);
    }

    // [Payables]
    function fund() external payable onlyOwner {
        require(!funded(), "already funded");
        IERC20(currency).transferFrom(
            msg.sender,
            address(this),
            initialFunding()
        );
        emit Funded(msg.sender, initialFunding());
    }

    function buy(
        bool outcome,
        uint256 shares,
        uint256 maxCost
    ) external payable {
        require(shares > 0, "invalid shares");
        require(!resolved, "market closed");

        uint256 cost = _quoteBuyCost(outcome, shares);
        require(cost <= maxCost, "slippage exceeded");

        // transfer currency to contract
        IERC20(currency).transferFrom(msg.sender, address(this), cost);

        // update market state
        if (outcome) {
            qYes += shares;
        } else {
            qNo += shares;
        }

        pool += cost;

        // update user shares
        if (outcome) {
            yesShares[msg.sender] += shares;
        } else {
            noShares[msg.sender] += shares;
        }

        emit Bought(msg.sender, outcome, shares, cost);
    }

    function sell(
        bool outcome,
        uint256 shares,
        uint256 minPayout
    ) external payable {
        require(shares > 0, "invalid shares");
        require(!resolved, "market closed");

        uint256 payout = _quoteSellPayout(outcome, shares);
        require(payout >= minPayout, "slippage exceeded");

        // update market state
        if (outcome) {
            qYes -= shares;
        } else {
            qNo -= shares;
        }

        pool -= payout;

        // update user shares
        if (outcome) {
            require(yesShares[msg.sender] >= shares, "insufficient shares");
            yesShares[msg.sender] -= shares;
        } else {
            require(noShares[msg.sender] >= shares, "insufficient shares");
            noShares[msg.sender] -= shares;
        }

        // transfer currency to user
        IERC20(currency).transfer(msg.sender, payout);
        emit Sold(msg.sender, outcome, shares, payout);
    }

    // [Admin]
    function resolve(bool outcome) external onlyOwner {
        require(!resolved, "already resolved");
        require(funded(), "not funded");
        resolved = true;

        emit Resolved(outcome);
    }

    function withdraw() external onlyOwner {
        require(resolved, "not resolved");
        require(qYes == 0 && qNo == 0, "shares outstanding");

        uint256 balance = IERC20(currency).balanceOf(address(this));
        require(balance > 0, "no balance");

        IERC20(currency).transfer(owner, balance);
        emit Withdrawn(owner, balance);
    }
}
