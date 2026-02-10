// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Mock token that charges a fee on every transfer (like some real tokens)
contract FeeOnTransferToken {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public feePercent = 10; // 10% fee on transfers

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * feePercent) / 100;
        uint256 amountAfterFee = amount - fee;
        
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amountAfterFee;
        // fee is burned
        totalSupply -= fee;
        
        emit Transfer(msg.sender, to, amountAfterFee);
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
        
        uint256 fee = (amount * feePercent) / 100;
        uint256 amountAfterFee = amount - fee;
        
        balanceOf[from] -= amount;
        balanceOf[to] += amountAfterFee;
        // fee is burned
        totalSupply -= fee;
        
        emit Transfer(from, to, amountAfterFee);
        return true;
    }
}
