// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
// Interfaces
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Contracts
import {UniswapHelper} from "@helper/UniswapHelper.sol";

contract DeployUniswapHelper is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        new UniswapHelper(
            IPoolManager(vm.envAddress("POOL_MANAGER_V4")),
            IPositionManager(vm.envAddress("POS_MANAGER_V4")),
            SemiFungiblePositionManager(vm.envAddress("SFPM"))
        );

        vm.stopBroadcast();
    }
}
