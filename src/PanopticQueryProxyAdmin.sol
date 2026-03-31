// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract PanopticQueryProxyAdmin is ProxyAdmin {
    constructor(address initialOwner) {
        _transferOwnership(initialOwner);
    }
}
