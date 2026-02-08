// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LMSRBetting} from "../src/LMSRBetting.sol";

contract Deploy is Script {
    function run() external returns (LMSRBetting deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(100));

        vm.startBroadcast(deployerPrivateKey);
        deployed = new LMSRBetting(deployer, feeRecipient, feeBps);
        vm.stopBroadcast();
    }
}
