// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EmergencyVaultWrapper} from "../src/EmergencyVaultWrapper.sol";

contract DeployScript is Script {
    function run() external returns (EmergencyVaultWrapper wrapper) {
        address owner = vm.envAddress("OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeRate = vm.envOr("FEE_RATE", uint256(0.02e18)); // default 2%
        vm.startBroadcast();
        wrapper = new EmergencyVaultWrapper(owner, feeRecipient, feeRate);
        vm.stopBroadcast();
        console.log("EmergencyVaultWrapper deployed at:", address(wrapper));
    }
}

