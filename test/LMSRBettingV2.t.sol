// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LMSRBettingV2Factory, LMSRBettingV2Market} from "../src/LMSRBettingV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";

contract LMSRBettingV2FactoryTest is Test {
    LMSRBettingV2Factory internal factory;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        factory = new LMSRBettingV2Factory(owner);
        token = new MockERC20("Test Token", "TEST");
    }

    function test_FactoryDeploymentSetsOwner() public view {
        assertEq(factory.owner(), owner);
    }

    function test_CreateMarket() public {
        address marketOwner = makeAddr("marketOwner");
        uint256 liquidity = 10 ether;

        vm.expectEmit(false, true, true, true);
        emit LMSRBettingV2Factory.MarketCreated(
            address(0), // we don't know the address yet
            "Test Market",
            marketOwner,
            address(token),
            liquidity
        );

        address market = factory.createMarket(
            "Test Market",
            marketOwner,
            address(token),
            liquidity
        );

        assertEq(factory.marketCount(), 1);
        assertEq(factory.getMarket(0), market);

        LMSRBettingV2Market marketContract = LMSRBettingV2Market(market);
        assertEq(marketContract.name(), "Test Market");
        assertEq(marketContract.owner(), marketOwner);
        assertEq(marketContract.currency(), address(token));
        assertEq(marketContract.liquidity(), liquidity);
    }

    function test_CreateMultipleMarkets() public {
        factory.createMarket("Market 1", alice, address(token), 5 ether);
        factory.createMarket("Market 2", alice, address(token), 10 ether);
        factory.createMarket("Market 3", alice, address(token), 15 ether);

        assertEq(factory.marketCount(), 3);

        address[] memory markets = factory.getAllMarkets();
        assertEq(markets.length, 3);
    }

    function test_RevertGetMarketInvalidIndex() public {
        vm.expectRevert("invalid index");
        factory.getMarket(0);
    }

    function test_TransferFactoryOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        assertEq(factory.owner(), newOwner);
    }

    function test_RevertTransferOwnershipUnauthorized() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(alice);
        vm.expectRevert("unauthorized");
        factory.transferOwnership(newOwner);
    }
}

contract LMSRBettingV2MarketTest is Test {
    LMSRBettingV2Market internal market;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    uint256 internal constant LIQUIDITY = 10 ether;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST");
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        // Mint tokens to users
        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);

        // Approve market contract
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(market), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_ConstructorSetsParameters() public view {
        assertEq(market.name(), "Test Market");
        assertEq(market.owner(), owner);
        assertEq(market.currency(), address(token));
        assertEq(market.liquidity(), LIQUIDITY);
        assertFalse(market.resolved());
        assertEq(market.qYes(), 0);
        assertEq(market.qNo(), 0);
        assertEq(market.pool(), 0);
    }

    function test_RevertConstructorWithZeroAddress() public {
        vm.expectRevert("invalid currency");
        new LMSRBettingV2Market("Test", owner, address(0), LIQUIDITY);
    }

    function test_RevertConstructorWithWalletAsCurrency() public {
        vm.expectRevert("invalid currency");
        new LMSRBettingV2Market("Test", owner, alice, LIQUIDITY);
    }

    function test_RevertConstructorWithZeroLiquidity() public {
        vm.expectRevert("invalid liquidity");
        new LMSRBettingV2Market("Test", owner, address(token), 0);
    }

    function test_RevertConstructorWithContractAsOwner() public {
        vm.expectRevert("owner is not a wallet");
        new LMSRBettingV2Market("Test", address(token), address(token), LIQUIDITY);
    }

    function test_RevertConstructorWithUnsupportedDecimals() public {
        MockERC20Decimals usdc = new MockERC20Decimals("USD Coin", "USDC", 6);
        vm.expectRevert("unsupported decimals");
        new LMSRBettingV2Market("Test", owner, address(usdc), LIQUIDITY);
    }

    // ============ Funding Tests ============

    function test_InitialFundingCalculation() public view {
        uint256 expectedFunding = (LIQUIDITY * 693147180559945309) / 1e18 + 1;
        assertApproxEqAbs(market.initialFunding(), expectedFunding, 1);
    }

    function test_Fund() public {
        uint256 fundingAmount = market.initialFunding();
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LMSRBettingV2Market.Funded(owner, fundingAmount);
        market.fund();

        assertTrue(market.funded());
        assertEq(token.balanceOf(address(market)), fundingAmount);
        assertEq(token.balanceOf(owner), ownerBalanceBefore - fundingAmount);
        assertEq(market.pool(), fundingAmount);
    }

    function test_RevertFundUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert("unauthorized");
        market.fund();
    }

    function test_RevertFundAlreadyFunded() public {
        vm.prank(owner);
        market.fund();

        vm.prank(owner);
        vm.expectRevert("already funded");
        market.fund();
    }

    function test_FundedReturnsFalseWhenNotFunded() public view {
        assertFalse(market.funded());
    }

    // ============ Buy Tests ============

    function test_BuyYesShares() public {
        _fundMarket();

        uint256 shares = 1 ether;
        uint256 cost = market.quoteBuyCost(true, shares);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 marketBalanceBefore = token.balanceOf(address(market));

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit LMSRBettingV2Market.Bought(alice, true, shares, cost);
        market.buy(true, shares, cost);

        assertEq(market.yesShares(alice), shares);
        assertEq(market.qYes(), shares);
        assertEq(token.balanceOf(alice), aliceBalanceBefore - cost);
        assertEq(token.balanceOf(address(market)), marketBalanceBefore + cost);
    }

    function test_BuyNoShares() public {
        _fundMarket();

        uint256 shares = 1 ether;
        uint256 cost = market.quoteBuyCost(false, shares);

        vm.prank(alice);
        market.buy(false, shares, cost);

        assertEq(market.noShares(alice), shares);
        assertEq(market.qNo(), shares);
    }

    function test_BuyMultipleTimesSameUser() public {
        _fundMarket();

        uint256 cost1 = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, cost1);

        uint256 cost2 = market.quoteBuyCost(true, 2 ether);
        vm.prank(alice);
        market.buy(true, 2 ether, cost2);

        assertEq(market.yesShares(alice), 3 ether);
        assertEq(market.qYes(), 3 ether);
    }

    function test_BuyIncreasesCostForSubsequentBuys() public {
        _fundMarket();

        uint256 cost1 = market.quoteBuyCost(true, 1 ether);

        vm.prank(alice);
        market.buy(true, 1 ether, cost1);

        uint256 cost2 = market.quoteBuyCost(true, 1 ether);

        assertGt(cost2, cost1);
    }

    function test_RevertBuyNotFunded() public {
        vm.prank(alice);
        vm.expectRevert("not funded");
        market.buy(true, 1 ether, 1 ether);
    }

    function test_RevertBuyZeroShares() public {
        _fundMarket();

        vm.prank(alice);
        vm.expectRevert("invalid shares");
        market.buy(true, 0, 0);
    }

    function test_RevertBuySlippageExceeded() public {
        _fundMarket();

        uint256 shares = 1 ether;
        uint256 cost = market.quoteBuyCost(true, shares);

        vm.prank(alice);
        vm.expectRevert("slippage exceeded");
        market.buy(true, shares, cost - 1);
    }

    function test_RevertBuyAfterResolution() public {
        _fundMarket();

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        vm.expectRevert("market closed");
        market.buy(true, 1 ether, 1 ether);
    }

    // ============ Sell Tests ============

    function test_SellYesShares() public {
        _fundMarket();

        uint256 shares = 2 ether;
        uint256 buyCost = market.quoteBuyCost(true, shares);
        vm.prank(alice);
        market.buy(true, shares, buyCost);

        uint256 sharesToSell = 1 ether;
        uint256 payout = market.quoteSellPayout(true, sharesToSell);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit LMSRBettingV2Market.Sold(alice, true, sharesToSell, payout);
        market.sell(true, sharesToSell, payout);

        assertEq(market.yesShares(alice), shares - sharesToSell);
        assertEq(market.qYes(), shares - sharesToSell);
        assertEq(token.balanceOf(alice), aliceBalanceBefore + payout);
    }

    function test_SellNoShares() public {
        _fundMarket();

        uint256 shares = 2 ether;
        uint256 buyCost = market.quoteBuyCost(false, shares);
        vm.prank(alice);
        market.buy(false, shares, buyCost);

        uint256 sharesToSell = 1 ether;
        uint256 payout = market.quoteSellPayout(false, sharesToSell);

        vm.prank(alice);
        market.sell(false, sharesToSell, payout);

        assertEq(market.noShares(alice), shares - sharesToSell);
        assertEq(market.qNo(), shares - sharesToSell);
    }

    function test_SellAllShares() public {
        _fundMarket();

        uint256 shares = 1 ether;
        uint256 buyCost = market.quoteBuyCost(true, shares);
        vm.prank(alice);
        market.buy(true, shares, buyCost);

        uint256 payout = market.quoteSellPayout(true, shares);

        vm.prank(alice);
        market.sell(true, shares, payout);

        assertEq(market.yesShares(alice), 0);
        assertEq(market.qYes(), 0);
    }

    function test_RevertSellNotFunded() public {
        vm.prank(alice);
        vm.expectRevert("not funded");
        market.sell(true, 1 ether, 0);
    }

    function test_RevertSellZeroShares() public {
        _fundMarket();

        vm.prank(alice);
        vm.expectRevert("invalid shares");
        market.sell(true, 0, 0);
    }

    function test_RevertSellInsufficientShares() public {
        _fundMarket();

        vm.prank(alice);
        vm.expectRevert("insufficient shares");
        market.sell(true, 1 ether, 0);
    }

    function test_RevertSellSlippageExceeded() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 2 ether);
        vm.prank(alice);
        market.buy(true, 2 ether, buyCost);

        uint256 payout = market.quoteSellPayout(true, 1 ether);

        vm.prank(alice);
        vm.expectRevert("slippage exceeded");
        market.sell(true, 1 ether, payout + 1);
    }

    function test_RevertSellAfterResolution() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, buyCost);

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        vm.expectRevert("market closed");
        market.sell(true, 1 ether, 0);
    }

    function test_RevertSellInsufficientMarketDepth() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, buyCost);

        vm.expectRevert("insufficient market depth");
        market.quoteSellPayout(true, 2 ether);
    }

    // ============ Quote Tests ============

    function test_QuoteBuyCostReturnsNonZero() public view {
        uint256 cost = market.quoteBuyCost(true, 1 ether);
        assertGt(cost, 0);
    }

    function test_QuoteSellPayoutReturnsNonZero() public {
        _fundMarket();

        uint256 cost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, cost);

        uint256 payout = market.quoteSellPayout(true, 0.5 ether);
        assertGt(payout, 0);
    }

    function test_RevertQuoteBuyZeroShares() public {
        vm.expectRevert("invalid shares");
        market.quoteBuyCost(true, 0);
    }

    function test_RevertQuoteSellZeroShares() public {
        vm.expectRevert("invalid shares");
        market.quoteSellPayout(true, 0);
    }

    function test_QuoteMatchesActualCost() public {
        _fundMarket();

        uint256 shares = 1 ether;
        uint256 quotedCost = market.quoteBuyCost(true, shares);

        uint256 poolBefore = market.pool();

        vm.prank(alice);
        market.buy(true, shares, quotedCost);

        uint256 poolAfter = market.pool();
        assertEq(poolAfter - poolBefore, quotedCost);
    }

    // ============ Resolution Tests ============

    function test_ResolveYes() public {
        _fundMarket();

        vm.prank(owner);
        vm.expectEmit(false, true, false, false);
        emit LMSRBettingV2Market.Resolved(true);
        market.resolve(true);

        assertTrue(market.resolved());
        assertTrue(market.winningOutcome());
    }

    function test_ResolveNo() public {
        _fundMarket();

        vm.prank(owner);
        market.resolve(false);

        assertTrue(market.resolved());
        assertFalse(market.winningOutcome());
    }

    function test_RevertResolveUnauthorized() public {
        _fundMarket();

        vm.prank(alice);
        vm.expectRevert("unauthorized");
        market.resolve(true);
    }

    function test_RevertResolveNotFunded() public {
        vm.prank(owner);
        vm.expectRevert("not funded");
        market.resolve(true);
    }

    function test_RevertResolveAlreadyResolved() public {
        _fundMarket();

        vm.prank(owner);
        market.resolve(true);

        vm.prank(owner);
        vm.expectRevert("already resolved");
        market.resolve(false);
    }

    // ============ Claim Tests ============

    function test_ClaimWinningSharesYes() public {
        _fundMarket();

        uint256 shares = 5 ether;
        uint256 buyCost = market.quoteBuyCost(true, shares);
        vm.prank(alice);
        market.buy(true, shares, buyCost);

        vm.prank(owner);
        market.resolve(true);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit LMSRBettingV2Market.Claimed(alice, true, shares);
        market.claim();

        assertEq(market.yesShares(alice), 0);
        assertEq(market.qYes(), 0);
        assertEq(token.balanceOf(alice), aliceBalanceBefore + shares);
    }

    function test_ClaimWinningSharesNo() public {
        _fundMarket();

        uint256 shares = 5 ether;
        uint256 buyCost = market.quoteBuyCost(false, shares);
        vm.prank(alice);
        market.buy(false, shares, buyCost);

        vm.prank(owner);
        market.resolve(false);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        market.claim();

        assertEq(market.noShares(alice), 0);
        assertEq(market.qNo(), 0);
        assertEq(token.balanceOf(alice), aliceBalanceBefore + shares);
    }

    function test_MultipleUsersClaim() public {
        _fundMarket();

        uint256 aliceShares = 3 ether;
        uint256 bobShares = 2 ether;

        uint256 aliceCost = market.quoteBuyCost(true, aliceShares);
        vm.prank(alice);
        market.buy(true, aliceShares, aliceCost);

        uint256 bobCost = market.quoteBuyCost(true, bobShares);
        vm.prank(bob);
        market.buy(true, bobShares, bobCost);

        vm.prank(owner);
        market.resolve(true);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 bobBalanceBefore = token.balanceOf(bob);

        vm.prank(alice);
        market.claim();

        vm.prank(bob);
        market.claim();

        assertEq(token.balanceOf(alice), aliceBalanceBefore + aliceShares);
        assertEq(token.balanceOf(bob), bobBalanceBefore + bobShares);
        assertEq(market.qYes(), 0);
    }

    function test_RevertClaimNotResolved() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, buyCost);

        vm.prank(alice);
        vm.expectRevert("not resolved");
        market.claim();
    }

    function test_RevertClaimNoShares() public {
        _fundMarket();

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        vm.expectRevert("no claimable shares");
        market.claim();
    }

    function test_RevertClaimLosingShares() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(false, 1 ether);
        vm.prank(alice);
        market.buy(false, 1 ether, buyCost);

        vm.prank(owner);
        market.resolve(true); // Yes wins, alice has No shares

        vm.prank(alice);
        vm.expectRevert("no claimable shares");
        market.claim();
    }

    function test_RevertClaimTwice() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, buyCost);

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        market.claim();

        vm.prank(alice);
        vm.expectRevert("no claimable shares");
        market.claim();
    }

    // ============ Withdraw Tests ============

    function test_WithdrawAfterAllWinnersClaim() public {
        _fundMarket();

        uint256 aliceCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, aliceCost);

        uint256 bobCost = market.quoteBuyCost(false, 2 ether);
        vm.prank(bob);
        market.buy(false, 2 ether, bobCost);

        vm.prank(owner);
        market.resolve(true); // Yes wins

        vm.prank(alice);
        market.claim();

        uint256 ownerBalanceBefore = token.balanceOf(owner);
        uint256 remainingBalance = token.balanceOf(address(market));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LMSRBettingV2Market.Withdrawn(owner, remainingBalance);
        market.withdraw();

        assertEq(token.balanceOf(owner), ownerBalanceBefore + remainingBalance);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_RevertWithdrawNotResolved() public {
        _fundMarket();

        vm.prank(owner);
        vm.expectRevert("not resolved");
        market.withdraw();
    }

    function test_RevertWithdrawWinnerSharesOutstanding() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, buyCost);

        vm.prank(owner);
        market.resolve(true);

        vm.prank(owner);
        vm.expectRevert("winner shares outstanding");
        market.withdraw();
    }

    function test_RevertWithdrawNoBalance() public {
        _fundMarket();

        uint256 buyCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, buyCost);

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        market.claim();

        // Manually drain the contract (simulating edge case)
        // Use deal to set market balance to 0
        deal(address(token), address(market), 0);

        vm.prank(owner);
        vm.expectRevert("no balance");
        market.withdraw();
    }

    function test_RevertWithdrawUnauthorized() public {
        _fundMarket();

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        vm.expectRevert("unauthorized");
        market.withdraw();
    }

    // ============ Ownership Tests ============

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        market.transferOwnership(newOwner);

        assertEq(market.owner(), newOwner);
    }

    function test_RevertTransferOwnershipUnauthorized() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(alice);
        vm.expectRevert("unauthorized");
        market.transferOwnership(newOwner);
    }

    function test_NewOwnerCanResolve() public {
        _fundMarket();

        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        market.transferOwnership(newOwner);

        vm.prank(newOwner);
        market.resolve(true);

        assertTrue(market.resolved());
    }

    // ============ Integration Tests ============

    function test_FullMarketLifecycle() public {
        // 1. Fund market
        _fundMarket();

        // 2. Multiple users buy shares
        uint256 aliceCost = market.quoteBuyCost(true, 3 ether);
        vm.prank(alice);
        market.buy(true, 3 ether, aliceCost);

        uint256 bobCost = market.quoteBuyCost(false, 2 ether);
        vm.prank(bob);
        market.buy(false, 2 ether, bobCost);

        uint256 charlieCost = market.quoteBuyCost(true, 1 ether);
        vm.prank(charlie);
        market.buy(true, 1 ether, charlieCost);

        // 3. Someone sells
        uint256 sellAmount = 0.5 ether;
        uint256 payout = market.quoteSellPayout(true, sellAmount);
        vm.prank(alice);
        market.sell(true, sellAmount, payout);

        // 4. Resolve market
        vm.prank(owner);
        market.resolve(true);

        // 5. Winners claim
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 charlieBalanceBefore = token.balanceOf(charlie);

        vm.prank(alice);
        market.claim();

        vm.prank(charlie);
        market.claim();

        // 6. Verify payouts
        assertEq(token.balanceOf(alice), aliceBalanceBefore + (3 ether - sellAmount));
        assertEq(token.balanceOf(charlie), charlieBalanceBefore + 1 ether);

        // 7. Owner withdraws remaining
        vm.prank(owner);
        market.withdraw();

        assertEq(token.balanceOf(address(market)), 0);
    }

    function test_BuyAndSellMovePrices() public {
        _fundMarket();

        // Initial state (approximately 50/50)
        uint256 initialYesCost = market.quoteBuyCost(true, 1 ether);
        uint256 initialNoCost = market.quoteBuyCost(false, 1 ether);

        // Buy Yes shares - should increase Yes cost, decrease No cost
        uint256 buyCost = market.quoteBuyCost(true, 5 ether);
        vm.prank(alice);
        market.buy(true, 5 ether, buyCost);

        uint256 afterBuyYesCost = market.quoteBuyCost(true, 1 ether);
        uint256 afterBuyNoCost = market.quoteBuyCost(false, 1 ether);

        assertGt(afterBuyYesCost, initialYesCost);
        assertLt(afterBuyNoCost, initialNoCost);
    }

    function test_LargeTradesWorkCorrectly() public {
        _fundMarket();

        uint256 largeShares = 50 ether;
        uint256 cost = market.quoteBuyCost(true, largeShares);

        vm.prank(alice);
        market.buy(true, largeShares, cost);

        assertEq(market.yesShares(alice), largeShares);
        assertEq(market.qYes(), largeShares);
    }

    function test_PoolAccountingIsAccurate() public {
        uint256 fundingAmount = market.initialFunding();
        _fundMarket();

        assertEq(market.pool(), fundingAmount);

        uint256 cost1 = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, cost1);

        assertEq(market.pool(), fundingAmount + cost1);

        uint256 cost2 = market.quoteBuyCost(false, 2 ether);
        vm.prank(bob);
        market.buy(false, 2 ether, cost2);

        assertEq(market.pool(), fundingAmount + cost1 + cost2);

        uint256 payout = market.quoteSellPayout(true, 0.5 ether);
        vm.prank(alice);
        market.sell(true, 0.5 ether, payout);

        assertEq(market.pool(), fundingAmount + cost1 + cost2 - payout);
    }

    // ============ Helper Functions ============

    function _fundMarket() internal {
        vm.prank(owner);
        market.fund();
    }
}
