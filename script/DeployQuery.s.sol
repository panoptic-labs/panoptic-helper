// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
import {PanopticQuery} from "@helper/PanopticQuery.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";

contract DeployQuery is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        new PanopticQuery(ISemiFungiblePositionManager(vm.envAddress("SFPM")));

        vm.stopBroadcast();
    }
}
