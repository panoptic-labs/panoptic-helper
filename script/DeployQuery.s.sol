// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import {Script, console} from "forge-std/Script.sol";
import {PanopticQuery} from "@helper/PanopticQuery.sol";
import {PanopticQueryProxyAdmin} from "@helper/PanopticQueryProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

interface IVanityMarket {
    function mint(address to, uint256 id, uint8 nonce) external;

    function deploy(uint256 id, bytes calldata initcode) external payable;
}

contract DeployQuery is Script {
    address internal constant DEFAULT_VANITY_MARKET = 0x000000000000b361194cfe6312EE3210d53C15AA;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address broadcaster = vm.addr(deployerPrivateKey);
        address proxyAdminOwner = vm.envOr("PANOPTIC_QUERY_PROXY_ADMIN_OWNER", broadcaster);
        bool useVanityProxy = vm.envOr("PANOPTIC_QUERY_PROXY_USE_VANITY", false);

        vm.startBroadcast(deployerPrivateKey);

        address implementation = address(new PanopticQuery());
        PanopticQueryProxyAdmin proxyAdmin = new PanopticQueryProxyAdmin(proxyAdminOwner);
        address proxy;

        if (useVanityProxy) {
            proxy = _deployVanityProxy(address(proxyAdmin), implementation, broadcaster);
        } else {
            proxy = address(
                new TransparentUpgradeableProxy(implementation, address(proxyAdmin), bytes(""))
            );
        }

        vm.stopBroadcast();

        console.log("PanopticQuery implementation:", implementation);
        console.log("PanopticQuery proxy:", proxy);
        console.log("PanopticQuery ProxyAdmin:", address(proxyAdmin));
        console.log("ProxyAdmin owner:", proxyAdmin.owner());
    }

    function _deployVanityProxy(
        address proxyAdmin,
        address implementation,
        address broadcaster
    ) internal returns (address proxy) {
        address vanityMarket = vm.envOr(
            "PANOPTIC_QUERY_PROXY_VANITY_MARKET",
            DEFAULT_VANITY_MARKET
        );
        address expectedProxy = vm.envAddress("PANOPTIC_QUERY_PROXY_ADDRESS");
        address saltOwner = vm.envOr("PANOPTIC_QUERY_PROXY_SALT_OWNER", broadcaster);
        bytes32 proxySalt = vm.envBytes32("PANOPTIC_QUERY_PROXY_SALT");
        bool mintSalt = vm.envOr("PANOPTIC_QUERY_PROXY_MINT", false);
        bool executeVanityDeployment = vm.envOr("PANOPTIC_QUERY_PROXY_EXECUTE", true);

        uint256 proxyNonceRaw = vm.envOr("PANOPTIC_QUERY_PROXY_NONCE", uint256(0));
        require(proxyNonceRaw <= type(uint8).max, "PANOPTIC_QUERY_PROXY_NONCE > uint8");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 proxyNonce = uint8(proxyNonceRaw);

        bytes memory proxyInitCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, bytes(""))
        );
        bytes memory mintCalldata = abi.encodeCall(
            IVanityMarket.mint,
            (saltOwner, uint256(proxySalt), proxyNonce)
        );
        bytes memory deployCalldata = abi.encodeCall(
            IVanityMarket.deploy,
            (uint256(proxySalt), proxyInitCode)
        );

        console.log("Vanity market:", vanityMarket);
        console.log("Expected vanity proxy:", expectedProxy);
        console.log("Vanity salt owner:", saltOwner);
        console.log("Vanity salt:");
        console.logBytes32(proxySalt);
        console.log("Vanity nonce:", proxyNonceRaw);
        console.log("Vanity mint calldata:");
        console.logBytes(mintCalldata);
        console.log("Vanity deploy calldata:");
        console.logBytes(deployCalldata);

        if (!executeVanityDeployment) {
            return expectedProxy;
        }

        if (mintSalt) {
            IVanityMarket(vanityMarket).mint(saltOwner, uint256(proxySalt), proxyNonce);
        }

        (bool success, bytes memory returndata) = vanityMarket.call(deployCalldata);
        require(success, "VANITY_PROXY_DEPLOY_FAILED");

        proxy = expectedProxy;
        if (returndata.length == 32) {
            address returnedProxy = abi.decode(returndata, (address));
            require(returnedProxy == expectedProxy, "VANITY_PROXY_ADDRESS_MISMATCH");
        }
        require(proxy.code.length != 0, "VANITY_PROXY_NOT_DEPLOYED");
    }
}
