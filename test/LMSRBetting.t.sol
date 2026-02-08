// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LMSRBetting} from "../src/LMSRBetting.sol";

contract LMSRBettingTest is Test {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    LMSRBetting internal betting;

    address internal owner = address(this);
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DEFAULT_FEE_BPS = 100;
    uint256 internal constant DEFAULT_B = 10 ether;

    uint64 internal closeTime;
    uint256 internal marketId;

    function setUp() public {
        betting = new LMSRBetting(owner, feeRecipient, DEFAULT_FEE_BPS);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        closeTime = uint64(block.timestamp + 1 days);
        uint256 subsidy = betting.requiredSubsidy(DEFAULT_B);

        marketId = betting.marketCount();
        betting.createMarket{value: subsidy}("Team A vs Team B", closeTime, DEFAULT_B);
    }

    function test_CreateMarketStoresData() public view {
        (
            string memory title,
            uint64 marketCloseTime,
            uint256 b,
            uint256 qYes,
            uint256 qNo,
            uint256 pool,
            bool resolved,
            uint8 winningOutcome,
            address creator
        ) = betting.getMarket(marketId);

        assertEq(title, "Team A vs Team B");
        assertEq(marketCloseTime, closeTime);
        assertEq(b, DEFAULT_B);
        assertEq(qYes, 0);
        assertEq(qNo, 0);
        assertEq(pool, betting.requiredSubsidy(DEFAULT_B));
        assertFalse(resolved);
        assertEq(winningOutcome, 0);
        assertEq(creator, owner);
    }

    function test_RevertCreateMarketWithInsufficientFunding() public {
        uint256 b = 5 ether;
        uint64 nextCloseTime = uint64(block.timestamp + 2 days);
        uint256 subsidy = betting.requiredSubsidy(b);

        vm.expectRevert(
            abi.encodeWithSelector(LMSRBetting.InsufficientFunding.selector, subsidy, subsidy - 1)
        );
        betting.createMarket{value: subsidy - 1}("Insufficient", nextCloseTime, b);
    }

    function test_BuyIncreasesSharesAndPool() public {
        uint256 shares = 1 ether;
        uint256 cost = betting.quoteBuyCost(marketId, 0, shares);
        uint256 fee = _feeOf(cost);

        (, , , , , uint256 poolBefore, , , ) = betting.getMarket(marketId);

        vm.prank(alice);
        betting.buy{value: cost + fee}(marketId, 0, shares, cost);

        (uint256 yesShares, uint256 noShares) = betting.getUserShares(marketId, alice);
        assertEq(yesShares, shares);
        assertEq(noShares, 0);

        (, , , , , uint256 poolAfter, , , ) = betting.getMarket(marketId);
        assertEq(poolAfter, poolBefore + cost);
    }

    function test_BuyMovesYesPriceUp() public {
        (uint256 yesBefore, ) = betting.getPriceWad(marketId);

        _buy(alice, 0, 2 ether);

        (uint256 yesAfter, ) = betting.getPriceWad(marketId);
        assertGt(yesAfter, yesBefore);
    }

    function test_SellPaysOutAndReducesShares() public {
        _buy(alice, 0, 2 ether);

        uint256 sharesToSell = 1 ether;
        uint256 payout = betting.quoteSellPayout(marketId, 0, sharesToSell);
        uint256 fee = _feeOf(payout);

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        betting.sell(marketId, 0, sharesToSell, payout);

        uint256 balanceAfter = alice.balance;

        (uint256 yesShares, ) = betting.getUserShares(marketId, alice);
        assertEq(yesShares, 1 ether);
        assertEq(balanceAfter, balanceBefore + payout - fee);
    }

    function test_RevertTradeAfterCloseTime() public {
        vm.warp(uint256(closeTime));

        vm.prank(alice);
        vm.expectRevert(LMSRBetting.MarketClosed.selector);
        betting.buy{value: 1 ether}(marketId, 0, 1 ether, 1 ether);
    }

    function test_OnlyOwnerCanResolve() public {
        vm.warp(uint256(closeTime) + 1);

        vm.prank(alice);
        vm.expectRevert(LMSRBetting.Unauthorized.selector);
        betting.resolve(marketId, 0);
    }

    function test_ResolveAndClaimWinnerOnce() public {
        _buy(alice, 0, 3 ether);
        _buy(bob, 1, 1 ether);

        vm.warp(uint256(closeTime) + 1);
        betting.resolve(marketId, 0);

        uint256 expectedPayout = 3 ether;
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        betting.claim(marketId);

        assertEq(alice.balance, aliceBalanceBefore + expectedPayout);

        vm.prank(alice);
        vm.expectRevert(LMSRBetting.NoClaimableShares.selector);
        betting.claim(marketId);

        vm.prank(bob);
        vm.expectRevert(LMSRBetting.NoClaimableShares.selector);
        betting.claim(marketId);
    }

    function test_RevertBuyWhenSlippageLimitTooLow() public {
        uint256 shares = 1 ether;
        uint256 cost = betting.quoteBuyCost(marketId, 0, shares);
        uint256 fee = _feeOf(cost);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LMSRBetting.SlippageExceeded.selector, cost - 1, cost));
        betting.buy{value: cost + fee}(marketId, 0, shares, cost - 1);
    }

    function test_QuoteMatchesBuyCostWhenNoStateChange() public {
        uint256 shares = 1 ether;
        uint256 quotedCost = betting.quoteBuyCost(marketId, 0, shares);
        uint256 fee = _feeOf(quotedCost);

        (, , , , , uint256 poolBefore, , , ) = betting.getMarket(marketId);

        vm.prank(alice);
        betting.buy{value: quotedCost + fee}(marketId, 0, shares, quotedCost);

        (, , , , , uint256 poolAfter, , , ) = betting.getMarket(marketId);
        assertEq(poolAfter, poolBefore + quotedCost);
    }

    function _buy(address user, uint8 outcome, uint256 shares) internal {
        uint256 quotedCost = betting.quoteBuyCost(marketId, outcome, shares);
        uint256 maxCost = quotedCost + (quotedCost * 100) / BPS_DENOMINATOR;
        uint256 maxFee = _feeOf(maxCost);

        vm.prank(user);
        betting.buy{value: maxCost + maxFee}(marketId, outcome, shares, maxCost);
    }

    function _feeOf(uint256 amount) internal view returns (uint256) {
        return (amount * betting.feeBps()) / BPS_DENOMINATOR;
    }
}
