// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PanopticQuery} from "../src/PanopticQuery.sol";
import {PanopticQueryProxyAdmin} from "../src/PanopticQueryProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract PanopticQueryProxyTest is Test {
    function testDeploysPanopticQueryBehindTransparentProxy() external {
        address adminOwner = address(0xBEEF);
        PanopticQuery implementation = new PanopticQuery();
        PanopticQueryProxyAdmin proxyAdmin = new PanopticQueryProxyAdmin(adminOwner);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            bytes("")
        );

        assertEq(
            proxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(payable(address(proxy)))
            ),
            address(implementation)
        );
        assertEq(
            proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(payable(address(proxy)))),
            address(proxyAdmin)
        );
        assertEq(proxyAdmin.owner(), adminOwner);
    }

    function testUpgradesPanopticQueryProxyImplementation() external {
        address adminOwner = address(this);
        PanopticQuery implementation = new PanopticQuery();
        PanopticQueryProxyAdmin proxyAdmin = new PanopticQueryProxyAdmin(adminOwner);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            bytes("")
        );
        PanopticQuery nextImplementation = new PanopticQuery();

        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            address(nextImplementation)
        );

        assertEq(
            proxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(payable(address(proxy)))
            ),
            address(nextImplementation)
        );
    }
}
