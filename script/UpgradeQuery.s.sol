// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import {Script, console} from "forge-std/Script.sol";
import {PanopticQuery} from "@helper/PanopticQuery.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradeQuery is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PANOPTIC_QUERY_PROXY_ADDRESS");
        address proxyAdminAddress = vm.envAddress("PANOPTIC_QUERY_PROXY_ADMIN");
        bool executeUpgrade = vm.envOr("PANOPTIC_QUERY_PROXY_EXECUTE", true);

        vm.startBroadcast(deployerPrivateKey);

        address implementation = address(new PanopticQuery());
        bytes memory upgradeCalldata = abi.encodeCall(
            ProxyAdmin.upgrade,
            (ITransparentUpgradeableProxy(payable(proxyAddress)), implementation)
        );

        if (executeUpgrade) {
            ProxyAdmin(proxyAdminAddress).upgrade(
                ITransparentUpgradeableProxy(payable(proxyAddress)),
                implementation
            );
        }

        vm.stopBroadcast();

        console.log("PanopticQuery proxy:", proxyAddress);
        console.log("PanopticQuery new implementation:", implementation);
        console.log("PanopticQuery ProxyAdmin:", proxyAdminAddress);
        console.log("ProxyAdmin upgrade calldata:");
        console.logBytes(upgradeCalldata);
    }
}
