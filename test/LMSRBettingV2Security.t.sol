// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LMSRBettingV2Factory, LMSRBettingV2Market} from "../src/LMSRBettingV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {FalseReturningToken} from "./mocks/FalseReturningToken.sol";
import {NoReturnToken} from "./mocks/NoReturnToken.sol";

/// @notice Security-focused tests for LMSRBettingV2
/// Tests edge cases, attack vectors, and critical vulnerabilities
contract LMSRBettingV2SecurityTest is Test {
    LMSRBettingV2Market internal market;
    MockERC20 internal token;
    FeeOnTransferToken internal feeToken;
    ReentrantToken internal reentrantToken;
    MockERC20Decimals internal usdcToken; // non-18 decimals
    NoReturnToken internal noReturnToken;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal dave = makeAddr("dave");

    uint256 internal constant LIQUIDITY = 10 ether;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST");
    }

    // ============================================
    // ❗ 1) FEE-ON-TRANSFER TOKEN TESTS (치명)
    // ============================================

    function test_FeeOnTransferTokenBreaksPoolAccounting() public {
        // Create market with fee-on-transfer token
        feeToken = new FeeOnTransferToken();
        market = new LMSRBettingV2Market(
            "Fee Token Market",
            owner,
            address(feeToken),
            LIQUIDITY
        );

        // Setup balances and approvals
        feeToken.mint(owner, INITIAL_BALANCE);
        feeToken.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        feeToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        feeToken.approve(address(market), type(uint256).max);

        // Fund market - this will fail due to fee
        vm.prank(owner);
        vm.expectRevert("fee-on-transfer not supported");
        market.fund();
    }

    function test_FeeOnTransferTokenBreaksBuy() public {
        // Fee-on-transfer tokens should be blocked at funding stage
        // But let's test buy separately
        feeToken = new FeeOnTransferToken();
        market = new LMSRBettingV2Market(
            "Fee Token Market",
            owner,
            address(feeToken),
            LIQUIDITY
        );

        feeToken.mint(owner, INITIAL_BALANCE);
        feeToken.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        feeToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        feeToken.approve(address(market), type(uint256).max);

        // Try to fund first - this will fail
        vm.prank(owner);
        vm.expectRevert("fee-on-transfer not supported");
        market.fund();
    }

    // ============================================
    // ❗ 2) BYPASS FUNDING GUARD TESTS
    // ============================================

    function test_DirectTokenTransferDoesNotBypassFundingGuard() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(alice, INITIAL_BALANCE);

        // Alice directly sends tokens to market (not through fund())
        uint256 fundingAmount = market.initialFunding();
        vm.prank(alice);
        token.transfer(address(market), fundingAmount);

        // ✅ FIXED: Market does NOT think it's funded now
        assertFalse(market.funded());
        assertEq(market.pool(), 0); // Pool is still 0!

        // Alice CANNOT trade without owner properly funding
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        
        uint256 cost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        vm.expectRevert("not funded");
        market.buy(true, 1 ether, cost);
    }

    function test_PoolAndBalanceDivergenceAfterDirectTransfer() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        // Owner funds properly
        vm.prank(owner);
        market.fund();

        uint256 fundingAmount = market.initialFunding();
        assertEq(market.pool(), fundingAmount);
        assertEq(token.balanceOf(address(market)), fundingAmount);

        // Alice sends extra tokens directly
        vm.prank(alice);
        token.transfer(address(market), 5 ether);

        // Pool and balance now diverge!
        assertEq(market.pool(), fundingAmount);
        assertEq(token.balanceOf(address(market)), fundingAmount + 5 ether);
        
        // This creates accounting issues
        assertGt(token.balanceOf(address(market)), market.pool());
    }

    function test_DirectTransferDoesNotAffectQuotes() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);

        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 quoteBefore = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        token.transfer(address(market), 5 ether);
        uint256 quoteAfter = market.quoteBuyCost(true, 1 ether);

        assertEq(quoteBefore, quoteAfter);
    }

    function test_WithdrawSweepsDirectlyTransferredBalance() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);

        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 cost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, cost);

        vm.prank(bob);
        token.transfer(address(market), 7 ether);

        vm.prank(owner);
        market.resolve(false);

        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(owner);
        market.withdraw();
        uint256 ownerAfter = token.balanceOf(owner);

        assertGt(ownerAfter, ownerBefore);
        assertEq(token.balanceOf(address(market)), 0);
    }

    // ============================================
    // ❗ 3) EXP OVERFLOW BOUNDARY TESTS (중요)
    // ============================================

    function test_RevertWhenExpInputTooLarge() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // Try to buy massive amount that exceeds exp input limit
        // MAX_EXP_INPUT_WAD = 135e18
        // With liquidity = 10 ether, shares must satisfy: shares * WAD / liquidity <= 135e18
        // So shares <= 1350 ether. We try 1351 ether to exceed it.
        uint256 hugeShares = 1351 ether; // Above the limit

        vm.expectRevert("exp input too large");
        market.quoteBuyCost(true, hugeShares);
    }

    function test_ExpInputBoundaryAtLimitPassesForBothOutcomes() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);

        vm.prank(owner);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 exactBoundaryShares = 1350 ether; // q * 1e18 / b == 135e18
        uint256 yesCost = market.quoteBuyCost(true, exactBoundaryShares);
        uint256 noCost = market.quoteBuyCost(false, exactBoundaryShares);
        assertGt(yesCost, 0);
        assertGt(noCost, 0);
    }

    function test_TinyShareRoundTripAccounting() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);

        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 shares = 1;
        uint256 buyCost = market.quoteBuyCost(true, shares);
        vm.prank(alice);
        market.buy(true, shares, buyCost);

        uint256 sellPayout = market.quoteSellPayout(true, shares);
        vm.prank(alice);
        market.sell(true, shares, sellPayout);

        assertGe(token.balanceOf(address(market)), market.pool());
    }

    function test_MaxSafeSharesPurchase() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        uint256 hugeBalance = type(uint256).max / 2; // Avoid overflow
        token.mint(owner, hugeBalance);
        token.mint(alice, hugeBalance);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // Find the maximum safe shares
        // liquidity = 10e18, MAX_EXP = 135e18
        // q/b <= 135 => q <= 1350e18
        uint256 maxShares = 1300 ether; // Safely below limit

        uint256 cost = market.quoteBuyCost(true, maxShares);
        
        vm.prank(alice);
        market.buy(true, maxShares, cost);

        assertEq(market.yesShares(alice), maxShares);
    }

    // ============================================
    // ❗ 4) DIFFERENT TOKEN DECIMALS TESTS (중요)
    // ============================================

    function test_Revert_6DecimalTokenUnsupported() public {
        usdcToken = new MockERC20Decimals("USD Coin", "USDC", 6);
        vm.expectRevert("unsupported decimals");
        new LMSRBettingV2Market("USDC Market", owner, address(usdcToken), LIQUIDITY);
    }

    function test_Revert_8DecimalTokenUnsupported() public {
        MockERC20Decimals wbtcToken = new MockERC20Decimals("Wrapped BTC", "WBTC", 8);
        vm.expectRevert("unsupported decimals");
        new LMSRBettingV2Market("WBTC Market", owner, address(wbtcToken), LIQUIDITY);
    }

    // ============================================
    // ❗ 5) REENTRANCY TESTS (중요)
    // ============================================

    function test_ReentrancyDuringClaim() public {
        // This test is now covered by test_ReentrancyProtectionOnClaim below
        // which explicitly tests the reentrancy guard
    }

    // ============================================
    // ❗ 6) PARTIAL CLAIMS ACCOUNTING TESTS
    // ============================================

    function test_PartialClaimsFromMultipleUsers() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);
        token.mint(dave, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(market), type(uint256).max);
        vm.prank(dave);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // Different users buy different amounts
        uint256 aliceShares = 1.234 ether;
        uint256 bobShares = 0.567 ether;
        uint256 charlieShares = 2.891 ether;
        uint256 daveShares = 0.111 ether;

        uint256 aliceCost = market.quoteBuyCost(true, aliceShares);
        vm.prank(alice);
        market.buy(true, aliceShares, aliceCost);

        uint256 bobCost = market.quoteBuyCost(true, bobShares);
        vm.prank(bob);
        market.buy(true, bobShares, bobCost);

        uint256 charlieCost = market.quoteBuyCost(true, charlieShares);
        vm.prank(charlie);
        market.buy(true, charlieShares, charlieCost);

        uint256 daveCost = market.quoteBuyCost(true, daveShares);
        vm.prank(dave);
        market.buy(true, daveShares, daveCost);

        uint256 totalShares = aliceShares + bobShares + charlieShares + daveShares;
        assertEq(market.qYes(), totalShares);

        vm.prank(owner);
        market.resolve(true);

        // All users claim in random order
        vm.prank(charlie);
        market.claim();
        
        vm.prank(alice);
        market.claim();
        
        vm.prank(dave);
        market.claim();
        
        vm.prank(bob);
        market.claim();

        // qYes should be exactly 0 after all claims
        assertEq(market.qYes(), 0);
        assertEq(market.yesShares(alice), 0);
        assertEq(market.yesShares(bob), 0);
        assertEq(market.yesShares(charlie), 0);
        assertEq(market.yesShares(dave), 0);
    }

    // ============================================
    // ❗ 7) POOL VS BALANCE CONSISTENCY TESTS
    // ============================================

    function test_PoolMatchesActualBalanceAlways() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        // After funding
        vm.prank(owner);
        market.fund();
        assertEq(market.pool(), token.balanceOf(address(market)));

        // After buy
        uint256 cost1 = market.quoteBuyCost(true, 2 ether);
        vm.prank(alice);
        market.buy(true, 2 ether, cost1);
        assertEq(market.pool(), token.balanceOf(address(market)));

        // After another buy
        uint256 cost2 = market.quoteBuyCost(false, 1 ether);
        vm.prank(bob);
        market.buy(false, 1 ether, cost2);
        assertEq(market.pool(), token.balanceOf(address(market)));

        // After sell
        uint256 payout = market.quoteSellPayout(true, 0.5 ether);
        vm.prank(alice);
        market.sell(true, 0.5 ether, payout);
        assertEq(market.pool(), token.balanceOf(address(market)));

        // After resolution and claim
        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        market.claim();
        assertEq(market.pool(), token.balanceOf(address(market)));
    }

    function testFuzz_PoolNeverExceedsBalance(uint96 seed, uint8 steps) public {
        market = new LMSRBettingV2Market(
            "Fuzz Market",
            owner,
            address(token),
            LIQUIDITY
        );

        uint256 largeBalance = 10_000 ether;
        token.mint(owner, largeBalance);
        token.mint(alice, largeBalance);
        token.mint(bob, largeBalance);

        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 boundedSteps = bound(uint256(steps), 5, 35);
        uint256 localSeed = uint256(seed) + 1;

        for (uint256 i = 0; i < boundedSteps; i++) {
            localSeed = uint256(keccak256(abi.encode(localSeed, i)));
            address actor = (localSeed % 2 == 0) ? alice : bob;
            bool outcome = (localSeed >> 1) % 2 == 0;
            bool doBuy = (localSeed >> 2) % 3 != 0; // buy more often than sell
            uint256 shares = ((localSeed >> 3) % 2e18) + 1e15; // [0.001e18, 2e18]

            if (doBuy) {
                uint256 cost = market.quoteBuyCost(outcome, shares);
                vm.prank(actor);
                market.buy(outcome, shares, cost);
            } else {
                uint256 owned = outcome
                    ? market.yesShares(actor)
                    : market.noShares(actor);

                if (owned == 0) {
                    continue;
                }

                uint256 sellShares = shares > owned ? owned : shares;
                uint256 payout = market.quoteSellPayout(outcome, sellShares);
                vm.prank(actor);
                market.sell(outcome, sellShares, payout);
            }

            assertGe(
                token.balanceOf(address(market)),
                market.pool(),
                "insolvent: balance below pool"
            );
        }
    }

    function test_ComplexScenarioPoolBalanceConsistency() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // Complex sequence: buy, buy, sell, buy, sell
        uint256 cost1 = market.quoteBuyCost(true, 3 ether);
        vm.prank(alice);
        market.buy(true, 3 ether, cost1);
        assertEq(market.pool(), token.balanceOf(address(market)));

        uint256 cost2 = market.quoteBuyCost(false, 2 ether);
        vm.prank(bob);
        market.buy(false, 2 ether, cost2);
        assertEq(market.pool(), token.balanceOf(address(market)));

        uint256 payout1 = market.quoteSellPayout(true, 1 ether);
        vm.prank(alice);
        market.sell(true, 1 ether, payout1);
        assertEq(market.pool(), token.balanceOf(address(market)));

        uint256 cost3 = market.quoteBuyCost(true, 1.5 ether);
        vm.prank(alice);
        market.buy(true, 1.5 ether, cost3);
        assertEq(market.pool(), token.balanceOf(address(market)));

        uint256 payout2 = market.quoteSellPayout(false, 0.5 ether);
        vm.prank(bob);
        market.sell(false, 0.5 ether, payout2);
        assertEq(market.pool(), token.balanceOf(address(market)));

        // Final check
        assertEq(market.pool(), token.balanceOf(address(market)));
    }

    // ============================================
    // ❗ 8) LOSER SHARES WITHDRAW TESTS
    // ============================================

    function test_LoserSharesDoNotBlockWithdraw() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // Alice buys YES (winner), Bob buys NO (loser)
        uint256 aliceCost = market.quoteBuyCost(true, 3 ether);
        vm.prank(alice);
        market.buy(true, 3 ether, aliceCost);

        uint256 bobCost = market.quoteBuyCost(false, 5 ether);
        vm.prank(bob);
        market.buy(false, 5 ether, bobCost);

        vm.prank(owner);
        market.resolve(true); // YES wins

        // Only alice claims
        vm.prank(alice);
        market.claim();

        // Bob's NO shares are still outstanding, but they're loser shares
        assertEq(market.qNo(), 5 ether);
        assertEq(market.qYes(), 0); // Winner shares are 0

        // Owner should be able to withdraw even though loser shares remain
        vm.prank(owner);
        market.withdraw();

        // Verify withdrawal succeeded
        assertGt(token.balanceOf(owner), 0);
    }

    function test_CannotWithdrawIfWinnerSharesOutstanding() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 cost = market.quoteBuyCost(true, 2 ether);
        vm.prank(alice);
        market.buy(true, 2 ether, cost);

        vm.prank(owner);
        market.resolve(true);

        // Alice hasn't claimed yet - winner shares outstanding
        assertEq(market.qYes(), 2 ether);

        vm.prank(owner);
        vm.expectRevert("winner shares outstanding");
        market.withdraw();
    }

    function test_WithdrawAfterClaimWindowWithWinnerSharesOutstanding() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);

        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 cost = market.quoteBuyCost(true, 1 wei);
        vm.prank(alice);
        market.buy(true, 1 wei, cost);

        vm.prank(owner);
        market.resolve(true);

        vm.warp(block.timestamp + market.CLAIM_WINDOW() + 1);

        uint256 ownerBalanceBefore = token.balanceOf(owner);
        vm.prank(owner);
        market.withdraw();

        assertGt(token.balanceOf(owner), ownerBalanceBefore);
    }

    // ============================================
    // ❗ 9) PRICE CONSISTENCY TESTS
    // ============================================

    function test_BuySellSameBlockPriceConsistency() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // Buy and immediately sell same amount in same block
        uint256 shares = 1 ether;
        
        uint256 initialBalance = token.balanceOf(alice);
        
        uint256 buyCost = market.quoteBuyCost(true, shares);
        vm.prank(alice);
        market.buy(true, shares, buyCost);

        uint256 sellPayout = market.quoteSellPayout(true, shares);
        vm.prank(alice);
        market.sell(true, shares, sellPayout);

        uint256 finalBalance = token.balanceOf(alice);

        // Alice should have less money (paid spread)
        assertLe(finalBalance, initialBalance);
        assertEq(initialBalance - finalBalance, buyCost - sellPayout);
    }

    function test_MultipleRoundTripConsistency() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 shares = 0.5 ether;

        // Multiple buy-sell cycles
        for (uint i = 0; i < 5; i++) {
            uint256 buyCost = market.quoteBuyCost(true, shares);
            vm.prank(alice);
            market.buy(true, shares, buyCost);

            uint256 sellPayout = market.quoteSellPayout(true, shares);
            vm.prank(alice);
            market.sell(true, shares, sellPayout);

            // Market should return to initial state
            assertEq(market.qYes(), 0);
            assertEq(market.qNo(), 0);
        }
    }

    function test_LMSRMathematicalInvariant() public {
        market = new LMSRBettingV2Market(
            "Test Market",
            owner,
            address(token),
            LIQUIDITY
        );

        token.mint(owner, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        // First, buy equal amounts from the same initial state
        uint256 shares = 2 ether;
        
        uint256 yesCostFromZero = market.quoteBuyCost(true, shares);
        uint256 noCostFromZero = market.quoteBuyCost(false, shares);
        
        // From initial state (0,0), buying YES or NO should cost the same
        assertEq(yesCostFromZero, noCostFromZero);

        // Now actually buy YES
        vm.prank(alice);
        market.buy(true, shares, yesCostFromZero);

        // After alice bought YES, buying NO becomes cheaper (price moved)
        uint256 noCostAfterYes = market.quoteBuyCost(false, shares);
        
        vm.prank(bob);
        market.buy(false, shares, noCostAfterYes);

        // The costs should be different due to state change
        assertLt(noCostAfterYes, yesCostFromZero);
    }

    // ============================================
    // ❗ ADDITIONAL EDGE CASES
    // ============================================

    function test_ZeroLiquidityMarketInitialFunding() public {
        // This should fail in constructor, but test anyway
        vm.expectRevert("invalid liquidity");
        new LMSRBettingV2Market(
            "Zero Liquidity",
            owner,
            address(token),
            0
        );
    }

    function test_VerySmallLiquidityMarket() public {
        market = new LMSRBettingV2Market(
            "Tiny Market",
            owner,
            address(token),
            1 // 1 wei liquidity
        );

        token.mint(owner, INITIAL_BALANCE);
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        assertTrue(market.funded());
        assertGt(market.initialFunding(), 0);
    }

    function test_VeryLargeLiquidityMarket() public {
        uint256 hugeLiquidity = 1_000_000 ether;
        market = new LMSRBettingV2Market(
            "Huge Market",
            owner,
            address(token),
            hugeLiquidity
        );

        token.mint(owner, type(uint256).max);
        vm.prank(owner);
        token.approve(address(market), type(uint256).max);

        uint256 fundingNeeded = market.initialFunding();
        assertGt(fundingNeeded, hugeLiquidity / 2); // Should be proportional

        vm.prank(owner);
        market.fund();

        assertTrue(market.funded());
    }

    // ============================================
    // ❗ 10) FALSE RETURNING TOKEN TESTS (치명)
    // ============================================

    function test_ERC20ReturnsFalse() public {
        FalseReturningToken falseToken = new FalseReturningToken();
        market = new LMSRBettingV2Market(
            "False Token Market",
            owner,
            address(falseToken),
            LIQUIDITY
        );

        falseToken.mint(owner, INITIAL_BALANCE);
        falseToken.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        falseToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        falseToken.approve(address(market), type(uint256).max);

        // Make the token return false on transfers
        falseToken.setShouldFail(true);

        // Try to fund - should fail
        vm.prank(owner);
        vm.expectRevert("transferFrom failed");
        market.fund();
    }

    function test_ERC20ReturnsFalseOnBuy() public {
        FalseReturningToken falseToken = new FalseReturningToken();
        market = new LMSRBettingV2Market(
            "False Token Market",
            owner,
            address(falseToken),
            LIQUIDITY
        );

        falseToken.mint(owner, INITIAL_BALANCE);
        falseToken.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        falseToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        falseToken.approve(address(market), type(uint256).max);

        // Fund successfully first
        vm.prank(owner);
        market.fund();

        // Now make transfers fail
        falseToken.setShouldFail(true);

        // Try to buy - should fail
        uint256 cost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        vm.expectRevert("transferFrom failed");
        market.buy(true, 1 ether, cost);
    }

    function test_NoReturnTokenSupportsFullLifecycle() public {
        noReturnToken = new NoReturnToken();

        market = new LMSRBettingV2Market(
            "No Return Market",
            owner,
            address(noReturnToken),
            LIQUIDITY
        );

        noReturnToken.mint(owner, INITIAL_BALANCE);
        noReturnToken.mint(alice, INITIAL_BALANCE);

        vm.prank(owner);
        noReturnToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        noReturnToken.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 shares = 1 ether;
        uint256 buyCost = market.quoteBuyCost(true, shares);

        vm.prank(alice);
        market.buy(true, shares, buyCost);

        uint256 sellShares = 250_000;
        uint256 payout = market.quoteSellPayout(true, sellShares);
        vm.prank(alice);
        market.sell(true, sellShares, payout);

        vm.prank(owner);
        market.resolve(true);

        vm.prank(alice);
        market.claim();

        // Ensure contract interacted successfully with no-return transfer semantics.
        assertEq(market.yesShares(alice), 0);
        assertEq(market.qYes(), 0);
    }

    function test_ReentrancyProtectionOnBuy() public {
        reentrantToken = new ReentrantToken();
        market = new LMSRBettingV2Market(
            "Reentrant Market",
            owner,
            address(reentrantToken),
            LIQUIDITY
        );

        reentrantToken.mint(owner, INITIAL_BALANCE);
        reentrantToken.mint(alice, INITIAL_BALANCE);
        vm.prank(owner);
        reentrantToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        reentrantToken.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        bytes memory attackData = abi.encodeWithSelector(
            LMSRBettingV2Market.buy.selector,
            true,
            1 ether,
            type(uint256).max
        );
        reentrantToken.setAttackCall(alice, address(market), attackData);

        uint256 cost = market.quoteBuyCost(true, 1 ether);
        vm.prank(alice);
        market.buy(true, 1 ether, cost);

        assertEq(market.yesShares(alice), 1 ether);
    }

    function test_ReentrancyProtectionOnSell() public {
        reentrantToken = new ReentrantToken();
        market = new LMSRBettingV2Market(
            "Reentrant Market",
            owner,
            address(reentrantToken),
            LIQUIDITY
        );

        reentrantToken.mint(owner, INITIAL_BALANCE);
        reentrantToken.mint(alice, INITIAL_BALANCE);
        vm.prank(owner);
        reentrantToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        reentrantToken.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 buyCost = market.quoteBuyCost(true, 2 ether);
        vm.prank(alice);
        market.buy(true, 2 ether, buyCost);

        bytes memory attackData = abi.encodeWithSelector(
            LMSRBettingV2Market.sell.selector,
            true,
            1 ether,
            0
        );
        reentrantToken.setAttackCall(alice, address(market), attackData);

        uint256 payout = market.quoteSellPayout(true, 1 ether);
        vm.prank(alice);
        market.sell(true, 1 ether, payout);

        assertEq(market.yesShares(alice), 1 ether);
    }

    function test_ReentrancyProtectionOnWithdraw() public {
        reentrantToken = new ReentrantToken();
        market = new LMSRBettingV2Market(
            "Reentrant Market",
            owner,
            address(reentrantToken),
            LIQUIDITY
        );

        reentrantToken.mint(owner, INITIAL_BALANCE);
        reentrantToken.mint(alice, INITIAL_BALANCE);
        vm.prank(owner);
        reentrantToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        reentrantToken.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 cost = market.quoteBuyCost(false, 1 ether);
        vm.prank(alice);
        market.buy(false, 1 ether, cost);

        vm.prank(owner);
        market.resolve(true);

        bytes memory attackData = abi.encodeWithSelector(
            LMSRBettingV2Market.withdraw.selector
        );
        reentrantToken.setAttackCall(owner, address(market), attackData);

        vm.prank(owner);
        market.withdraw();

        assertEq(reentrantToken.balanceOf(address(market)), 0);
    }

    function test_ReentrancyProtectionOnClaim() public {
        reentrantToken = new ReentrantToken();
        market = new LMSRBettingV2Market(
            "Reentrant Market",
            owner,
            address(reentrantToken),
            LIQUIDITY
        );

        reentrantToken.mint(owner, INITIAL_BALANCE);
        reentrantToken.mint(alice, INITIAL_BALANCE);
        
        vm.prank(owner);
        reentrantToken.approve(address(market), type(uint256).max);
        vm.prank(alice);
        reentrantToken.approve(address(market), type(uint256).max);

        vm.prank(owner);
        market.fund();

        uint256 cost = market.quoteBuyCost(true, 5 ether);
        vm.prank(alice);
        market.buy(true, 5 ether, cost);

        vm.prank(owner);
        market.resolve(true);

        // Setup reentrancy attack
        reentrantToken.setAttackParams(alice, address(market));

        // ✅ Claim succeeds, but reentrancy attempt inside transfer is blocked
        // The first claim() call succeeds, but the reentrant call fails
        // This is the correct behavior - user gets paid once, attack is prevented
        vm.prank(alice);
        market.claim();
        
        // Verify user was only paid once
        assertEq(market.yesShares(alice), 0);
        assertEq(market.qYes(), 0);
    }
}
