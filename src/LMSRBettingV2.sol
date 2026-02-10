// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";
import {Ownable} from "./utils/Ownable.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

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
    bool public winningOutcome;
    uint256 public resolvedAt;

    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;

    // contract address of ERC-20 currency
    address public currency;

    // resolved?
    bool public resolved;

    // Has been properly funded through fund() function
    bool private _hasBeenFunded;

    // Reentrancy guard
    uint256 private _locked = 1;

    // [Immutables]
    uint256 public immutable liquidity;

    // [Constants]
    uint256 private constant LN_2_WAD = 693147180559945309;
    uint256 private constant MAX_EXP_INPUT_WAD = 135e18;
    uint256 private constant WAD = 1e18;
    uint256 public constant CLAIM_WINDOW = 180 days;

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

    event Claimed(address indexed user, bool indexed outcome, uint256 shares);

    event Funded(address indexed funder, uint256 amount);

    event Resolved(bool indexed outcome);

    event Withdrawn(address indexed recipient, uint256 amount);

    // [Modifiers]
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

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
        require(
            IERC20Metadata(_currency).decimals() == 18,
            "unsupported decimals"
        );
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
        return FixedPointMathLib.fullMulDivUp(liquidity, LN_2_WAD, WAD);
    }

    function funded() public view returns (bool) {
        return _hasBeenFunded;
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

    // [Mutators]
    function fund() external onlyOwner nonReentrant {
        require(!_hasBeenFunded, "already funded");
        uint256 need = initialFunding();
        uint256 beforeBal = IERC20(currency).balanceOf(address(this));
        _safeTransferFrom(currency, msg.sender, address(this), need);
        uint256 afterBal = IERC20(currency).balanceOf(address(this));

        require(afterBal - beforeBal == need, "fee-on-transfer not supported");

        _hasBeenFunded = true;
        pool += need; // subsidy도 pool에 포함시키려면 이렇게
        emit Funded(msg.sender, need);
    }

    function buy(
        bool outcome,
        uint256 shares,
        uint256 maxCost
    ) external nonReentrant {
        require(shares > 0, "invalid shares");
        require(!resolved, "market closed");
        require(funded(), "not funded"); // 거래 전 펀딩 강제(권장)

        uint256 cost = _quoteBuyCost(outcome, shares);
        require(cost <= maxCost, "slippage exceeded");

        uint256 beforeBal = IERC20(currency).balanceOf(address(this));
        _safeTransferFrom(currency, msg.sender, address(this), cost);
        uint256 afterBal = IERC20(currency).balanceOf(address(this));
        require(afterBal - beforeBal == cost, "fee-on-transfer not supported");

        if (outcome) {
            qYes += shares;
            yesShares[msg.sender] += shares;
        } else {
            qNo += shares;
            noShares[msg.sender] += shares;
        }

        pool += cost;
        emit Bought(msg.sender, outcome, shares, cost);
    }

    function sell(
        bool outcome,
        uint256 shares,
        uint256 minPayout
    ) external nonReentrant {
        require(shares > 0, "invalid shares");
        require(!resolved, "market closed");
        require(funded(), "not funded");

        // 먼저 유저 보유 체크
        if (outcome) {
            require(yesShares[msg.sender] >= shares, "insufficient shares");
        } else {
            require(noShares[msg.sender] >= shares, "insufficient shares");
        }

        uint256 payout = _quoteSellPayout(outcome, shares);
        require(payout >= minPayout, "slippage exceeded");

        // state update
        if (outcome) {
            qYes -= shares;
            yesShares[msg.sender] -= shares;
        } else {
            qNo -= shares;
            noShares[msg.sender] -= shares;
        }
        pool -= payout;

        uint256 beforeBal = IERC20(currency).balanceOf(address(this));
        _safeTransfer(currency, msg.sender, payout);
        uint256 afterBal = IERC20(currency).balanceOf(address(this));
        require(
            beforeBal - afterBal == payout,
            "fee-on-transfer not supported"
        );

        emit Sold(msg.sender, outcome, shares, payout);
    }

    // [Admin]
    function resolve(bool outcome) external onlyOwner {
        require(!resolved, "already resolved");
        require(funded(), "not funded");
        resolved = true;
        winningOutcome = outcome;
        resolvedAt = block.timestamp;
        emit Resolved(outcome);
    }

    function withdraw() external onlyOwner nonReentrant {
        require(resolved, "not resolved");

        // Before the claim window ends, winners must claim before owner sweep.
        // After the deadline, owner can sweep unclaimed balances to prevent griefing locks.
        if (winningOutcome) {
            if (qYes > 0) {
                require(
                    block.timestamp >= resolvedAt + CLAIM_WINDOW,
                    "winner shares outstanding"
                );
            }
        } else {
            if (qNo > 0) {
                require(
                    block.timestamp >= resolvedAt + CLAIM_WINDOW,
                    "winner shares outstanding"
                );
            }
        }

        uint256 balance = IERC20(currency).balanceOf(address(this));
        require(balance > 0, "no balance");

        _safeTransfer(currency, owner, balance);
        emit Withdrawn(owner, balance);
    }

    function claim() external nonReentrant {
        require(resolved, "not resolved");

        uint256 shares = winningOutcome
            ? yesShares[msg.sender]
            : noShares[msg.sender];
        require(shares > 0, "no claimable shares");

        // burn user shares
        if (winningOutcome) {
            yesShares[msg.sender] = 0;
            // 중요: winner-side 총 발행량 감소 (withdraw 조건 만들기 위함)
            qYes -= shares;
        } else {
            noShares[msg.sender] = 0;
            qNo -= shares;
        }

        // accounting
        pool -= shares;

        _safeTransfer(currency, msg.sender, shares);

        emit Claimed(msg.sender, winningOutcome, shares);
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                amount
            )
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "transferFrom failed"
        );
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(
            ok && (data.length == 0 || abi.decode(data, (bool))),
            "transfer failed"
        );
    }
}
