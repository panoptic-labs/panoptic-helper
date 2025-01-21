// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UniswapMigrator} from "@helper/UniswapMigrator.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PanopticMath} from "@contracts/libraries/PanopticMath.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {Pointer} from "@types/Pointer.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PeripheryErrors} from "@helper/PeripheryErrors.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/interfaces/IPositionDescriptor.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

contract UniswapMigratorTest is Test {
    SemiFungiblePositionManager sfpm;

    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager V3NFPM =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    PanopticFactory factory;

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    IERC20Partial USDC = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    PanopticPool pp;

    PositionManager V4_PM;

    PoolKey poolKey;
    PoolKey poolKey_n;

    // USDC-ETH native
    PanopticPool pp_n;
    CollateralTracker ct0;
    CollateralTracker ct1;

    CollateralTracker ct0_n;
    CollateralTracker ct1_n;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Charlie = address(0x1234567891);

    uint256 amount0Migrate;
    uint256 amount1Migrate;

    uint256 tokenId;
    uint256[] tokenIds;
    uint256[2][] amount0Mins;
    uint256 amount0;
    uint256 amount1;

    // reference implemenatations used by the factory
    address poolReference;
    address collateralReference;

    UniswapMigrator uniswapMigrator;

    function setUp() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(0))));
        IPositionManager posManager = IPositionManager(
            address(
                new PositionManager(
                    manager,
                    IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
                    0,
                    IPositionDescriptor(address(0)),
                    IWETH9(address(WETH))
                )
            )
        );

        V4_PM = PositionManager(payable(address(posManager)));

        poolKey = PoolKey(
            Currency.wrap(address(USDC)),
            Currency.wrap(address(WETH)),
            500,
            10,
            IHooks(address(0))
        );

        poolKey_n = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(USDC)),
            500,
            10,
            IHooks(address(0))
        );

        manager.initialize(poolKey, 2 ** 96);
        manager.initialize(poolKey_n, 2 ** 96);

        sfpm = new SemiFungiblePositionManager(manager, 10 ** 13, 10 ** 13, 0);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(sfpm, manager));

        // no commission/mint fee
        collateralReference = address(
            new CollateralTracker(0, 2_000, 1_000, -1_024, 5_000, 9_000, 20, manager)
        );

        vm.startPrank(Deployer);

        factory = new PanopticFactory(
            sfpm,
            manager,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        uniswapMigrator = new UniswapMigrator(V3NFPM, posManager, IWETH9(address(WETH)));

        deal(address(USDC), Deployer, type(uint104).max);
        deal(address(WETH), Deployer, type(uint104).max);
        deal(Deployer, type(uint104).max);
        USDC.approve(address(factory), type(uint104).max);
        WETH.approve(address(factory), type(uint104).max);

        pp = PanopticPool(
            address(
                factory.deployNewPool(
                    IV3CompatibleOracle(address(USDC_WETH_5)),
                    poolKey,
                    uint96(block.timestamp)
                )
            )
        );

        pp_n = PanopticPool(
            address(
                factory.deployNewPool(
                    IV3CompatibleOracle(address(USDC_WETH_5)),
                    poolKey_n,
                    uint96(block.timestamp)
                )
            )
        );

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        ct0_n = pp_n.collateralToken0();
        ct1_n = pp_n.collateralToken1();

        deal(address(USDC), Alice, type(uint104).max);
        deal(address(WETH), Alice, type(uint104).max);
        deal(Alice, type(uint104).max);
        vm.startPrank(Alice);
        USDC.approve(address(V3NFPM), type(uint104).max);
        WETH.approve(address(V3NFPM), type(uint104).max);
        USDC.approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint104).max);
        WETH.approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint104).max);
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3).approve(
            address(USDC),
            address(V4_PM),
            type(uint104).max,
            type(uint48).max
        );
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3).approve(
            address(WETH),
            address(V4_PM),
            type(uint104).max,
            type(uint48).max
        );
        V3NFPM.setApprovalForAll(address(uniswapMigrator), true);
        IERC721(address(V4_PM)).setApprovalForAll(address(uniswapMigrator), true);

        deal(address(USDC), Bob, type(uint104).max);
        deal(address(WETH), Bob, type(uint104).max);
        deal(Bob, type(uint104).max);
        vm.startPrank(Bob);
        USDC.approve(address(V3NFPM), type(uint104).max);
        WETH.approve(address(V3NFPM), type(uint104).max);
        USDC.approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint104).max);
        WETH.approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint104).max);
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3).approve(
            address(USDC),
            address(V4_PM),
            type(uint104).max,
            type(uint48).max
        );
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3).approve(
            address(WETH),
            address(V4_PM),
            type(uint104).max,
            type(uint48).max
        );
        V3NFPM.setApprovalForAll(address(uniswapMigrator), true);
        IERC721(address(V4_PM)).setApprovalForAll(address(uniswapMigrator), true);
    }

    function test_success_migrateV3_single() public {
        vm.startPrank(Alice);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Alice,
                deadline: block.timestamp
            })
        );

        uniswapMigrator.migrateV3(tokenId, 0, 0, false, new address[](0), new bytes[](0), ct0, ct1);

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), amount0, 1);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), amount1, 1);
    }

    function test_success_migrateV4_single() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        uniswapMigrator.migrateV4(
            1,
            0,
            0,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );

        // err = rounded down shares
        assertApproxEqAbs(ct0_n.convertToAssets(ct0_n.balanceOf(Alice)), 10 ** 18, 1);
        assertApproxEqAbs(ct1_n.convertToAssets(ct1_n.balanceOf(Alice)), 10 ** 18, 1);
    }

    function test_success_migrateV4_single_nonNative() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(USDC, WETH);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        uniswapMigrator.migrateV4(
            1,
            0,
            0,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0,
            ct1,
            ""
        );

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), 10 ** 18, 1);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), 10 ** 18, 1);
    }

    function test_success_migrateV3_single_only0() public {
        vm.startPrank(Alice);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: 887260,
                tickUpper: 887270,
                amount0Desired: 100,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Alice,
                deadline: block.timestamp
            })
        );

        uniswapMigrator.migrateV3(tokenId, 0, 0, false, new address[](0), new bytes[](0), ct0, ct1);

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), amount0, 1);
        assertEq(ct1.balanceOf(Alice), 0);
    }

    function test_success_migrateV4_single_only0() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, 10, 20, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        uniswapMigrator.migrateV4(
            1,
            0,
            0,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );

        // err = rounded down shares
        assertApproxEqAbs(ct0_n.convertToAssets(ct0_n.balanceOf(Alice)), 499600184935518, 1);
        assertApproxEqAbs(ct1_n.convertToAssets(ct1_n.balanceOf(Alice)), 0, 0);
    }

    function test_success_migrateV3_single_only1() public {
        vm.startPrank(Alice);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: -887260,
                amount0Desired: 0,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Alice,
                deadline: block.timestamp
            })
        );

        uniswapMigrator.migrateV3(tokenId, 0, 0, false, new address[](0), new bytes[](0), ct0, ct1);

        // err = rounded down shares
        assertEq(ct0.balanceOf(Alice), 0);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), amount1, 1);
    }

    function test_success_migrateV4_single_only1() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -20, -10, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        uniswapMigrator.migrateV4(
            1,
            0,
            0,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );

        // err = rounded down shares
        assertApproxEqAbs(ct0_n.convertToAssets(ct0_n.balanceOf(Alice)), 0, 0);
        assertApproxEqAbs(ct1_n.convertToAssets(ct1_n.balanceOf(Alice)), 499600184935518, 1);
    }

    function test_success_migrateV3_multiple() public {
        vm.startPrank(Alice);

        bytes[] memory calls = new bytes[](32);

        for (uint256 i = 0; i < 32; ++i) {
            (tokenId, , amount0, amount1) = V3NFPM.mint(
                INonfungiblePositionManager.MintParams({
                    token0: address(USDC),
                    token1: address(WETH),
                    fee: 500,
                    tickLower: -887270,
                    tickUpper: 887270,
                    amount0Desired: 1000 * 10 ** 6 * ((i % 6) + 1),
                    amount1Desired: 1 ether * ((i % 6) + 1),
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: Alice,
                    deadline: block.timestamp
                })
            );

            amount0Migrate += amount0;
            amount1Migrate += amount1;

            tokenIds.push(tokenId);
            amount0Mins.push([0, 0]);

            calls[i] = abi.encodeWithSelector(
                uniswapMigrator.migrateV3.selector,
                tokenId,
                0,
                0,
                false,
                new address[](0),
                new bytes[](0),
                ct0,
                ct1
            );
        }

        uniswapMigrator.multicall(calls);

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), amount0Migrate, 32);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), amount1Migrate, 32);
    }

    function test_fail_migrateV3_single_unauthorized() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        vm.startPrank(Alice);

        vm.expectRevert(PeripheryErrors.UnauthorizedMigration.selector);
        uniswapMigrator.migrateV3(tokenId, 0, 0, false, new address[](0), new bytes[](0), ct0, ct1);
    }

    function test_fail_migrateV4_unauthorized() public {
        vm.startPrank(Bob);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Bob, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        vm.startPrank(Alice);

        vm.expectRevert(PeripheryErrors.UnauthorizedMigration.selector);
        uniswapMigrator.migrateV4(
            1,
            0,
            0,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );
    }

    function test_fail_migrateV3_single_slippage0() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        vm.startPrank(Alice);

        vm.expectRevert();
        uniswapMigrator.migrateV3(
            tokenId,
            amount0 + 1,
            0,
            false,
            new address[](0),
            new bytes[](0),
            ct0,
            ct1
        );
    }

    function test_fail_migrateV4_slippage0() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        vm.expectRevert();
        uniswapMigrator.migrateV4(
            1,
            10 ** 18 + 1,
            0,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );
    }

    function test_fail_migrateV3_single_slippage1() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        vm.startPrank(Alice);

        vm.expectRevert();
        uniswapMigrator.migrateV3(
            tokenId,
            0,
            amount1 + 1,
            false,
            new address[](0),
            new bytes[](0),
            ct0,
            ct1
        );
    }

    function test_fail_migrateV4_slippage1() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        vm.expectRevert();
        uniswapMigrator.migrateV4(
            1,
            0,
            10 ** 18 + 1,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );
    }

    function test_fail_migrateV3_single_slippageboth() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        vm.startPrank(Alice);

        vm.expectRevert();
        uniswapMigrator.migrateV3(
            tokenId,
            amount0 + 1,
            amount1 + 1,
            false,
            new address[](0),
            new bytes[](0),
            ct0,
            ct1
        );
    }

    function test_fail_migrateV4_slippageBoth() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        vm.expectRevert();
        uniswapMigrator.migrateV4(
            1,
            10 ** 18 + 1,
            10 ** 18 + 1,
            new address[](0),
            new bytes[](0),
            new uint256[](0),
            ct0_n,
            ct1_n,
            ""
        );
    }

    function test_fail_migrateV3_InvalidSwapAddress() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        address[] memory swapAddresses = new address[](2);
        swapAddresses[0] = address(0);
        swapAddresses[1] = address(V3NFPM);

        bytes[] memory swapCalls = new bytes[](2);

        vm.expectRevert(PeripheryErrors.InvalidSwapAddress.selector);
        uniswapMigrator.migrateV3(tokenId, 0, 0, false, swapAddresses, swapCalls, ct0, ct1);

        swapAddresses = new address[](1);
        swapAddresses[0] = address(V4_PM);

        swapCalls = new bytes[](1);

        vm.expectRevert(PeripheryErrors.InvalidSwapAddress.selector);
        uniswapMigrator.migrateV3(tokenId, 0, 0, false, swapAddresses, swapCalls, ct0, ct1);
    }

    function test_fail_migrateV4_InvalidSwapAddress() public {
        vm.startPrank(Alice);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey_n, -887270, 887270, 10 ** 18, 2 ** 127, 2 ** 127, Alice, "");
        params[1] = abi.encode(address(0), USDC);

        V4_PM.modifyLiquidities{value: 2 ** 96}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );

        address[] memory swapAddresses = new address[](2);
        swapAddresses[0] = address(0);
        swapAddresses[1] = address(V3NFPM);

        bytes[] memory swapCalls = new bytes[](2);

        uint256[] memory swapValues = new uint256[](2);

        vm.expectRevert(PeripheryErrors.InvalidSwapAddress.selector);
        uniswapMigrator.migrateV4(1, 0, 0, swapAddresses, swapCalls, swapValues, ct0_n, ct1_n, "");

        swapAddresses = new address[](1);
        swapAddresses[0] = address(V4_PM);

        swapCalls = new bytes[](1);
        swapValues = new uint256[](1);

        vm.expectRevert(PeripheryErrors.InvalidSwapAddress.selector);
        uniswapMigrator.migrateV4(1, 0, 0, swapAddresses, swapCalls, swapValues, ct0_n, ct1_n, "");
    }
}
