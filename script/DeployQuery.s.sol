// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
import {PanopticQuery} from "@helper/PanopticQuery.sol";
import {TokenIdHelper} from "@helper/TokenIdHelper.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";

contract DeployQuery is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        TokenIdHelper tih = new TokenIdHelper(SemiFungiblePositionManager(vm.envAddress("SFPM")));
        new PanopticQuery(SemiFungiblePositionManager(vm.envAddress("SFPM")), tih);

        vm.stopBroadcast();
    }
}
