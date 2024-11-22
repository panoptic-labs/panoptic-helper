// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
// Interfaces
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Contracts
import {UniswapHelper} from "@helper/UniswapHelper.sol";

contract DeployUniswapHelper is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        new UniswapHelper(
            IUniswapV3Factory(vm.envAddress("UNIV3_FACTORY")),
            INonfungiblePositionManager(vm.envAddress("NFPM")),
            SemiFungiblePositionManager(vm.envAddress("SFPM"))
        );

        vm.stopBroadcast();
    }
}
