// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LMSRBettingV2Market} from "../../src/LMSRBettingV2.sol";

/// @notice Malicious token that attempts reentrancy during transfer
contract ReentrantToken {
    string public name = "Reentrant Token";
    string public symbol = "REENT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public attacker;
    LMSRBettingV2Market public targetMarket;
    bool public shouldAttack;
    bool private attacking;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setAttackParams(address _attacker, address _market) external {
        attacker = _attacker;
        targetMarket = LMSRBettingV2Market(_market);
        shouldAttack = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        
        // Attempt reentrancy if conditions are met
        if (shouldAttack && !attacking && msg.sender == address(targetMarket)) {
            attacking = true;
            // Try to reenter during transfer (e.g., during claim payout)
            try targetMarket.claim() {} catch {}
            attacking = false;
        }
        
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        
        emit Transfer(from, to, amount);
        return true;
    }
}
