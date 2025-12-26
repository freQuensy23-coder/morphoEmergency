// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EmergencyVaultWrapper} from "../src/EmergencyVaultWrapper.sol";

contract DeployScript is Script {
    function run() external returns (EmergencyVaultWrapper wrapper) {
        address owner = vm.envAddress("OWNER");
        vm.startBroadcast();
        wrapper = new EmergencyVaultWrapper(owner);
        vm.stopBroadcast();
        console.log("EmergencyVaultWrapper deployed at:", address(wrapper));
    }
}

