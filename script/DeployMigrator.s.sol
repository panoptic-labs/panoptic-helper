// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
// Interfaces
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
// Contracts
import {UniswapMigrator} from "@helper/UniswapMigrator.sol";

contract DeployMigrator is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        new UniswapMigrator(
            INonfungiblePositionManager(vm.envAddress("NFPM")),
            IPositionManager(vm.envAddress("V4_POSM")),
            IWETH9(vm.envAddress("WETH"))
        );

        vm.stopBroadcast();
    }
}
