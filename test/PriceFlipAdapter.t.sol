// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "univ3-core/libraries/TickMath.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {Pointer} from "@types/Pointer.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PositionUtils} from "@testutils-v1-core/PositionUtils.sol";
import {Math} from "@libraries/Math.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
import {Errors} from "@libraries/Errors.sol";
import {Constants} from "@libraries/Constants.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC20S} from "@testutils-v1-core/ERC20S.sol";
import {PriceFlipAdapter} from "../src/PriceFlipAdapter.sol";
import {PriceFlipAdapterFactory} from "../src/PriceFlipAdapterFactory.sol";

// V4 types
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// Helper contract for swapping
contract SwapperC {
    struct PoolFeatures {
        address token0;
        address token1;
        uint24 fee;
    }

    struct CallbackData {
        PoolFeatures poolFeatures;
        address payer;
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackData memory decoded = abi.decode(data, (CallbackData));

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta > 0
            ? address(decoded.poolFeatures.token0)
            : address(decoded.poolFeatures.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        // the pool will always pass one delta with a positive sign and one with a negative sign or zero,
        // so this logic always picks the correct delta to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        SafeTransferLib.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        CallbackData memory decoded = abi.decode(data, (CallbackData));

        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    function mint(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 amount) public {
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            amount,
            abi.encode(
                CallbackData({
                    poolFeatures: PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function burn(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 amount) public {
        pool.burn(tickLower, tickUpper, amount);
    }

    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) public {
        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            type(int128).max,
            sqrtPriceX96,
            abi.encode(
                CallbackData({
                    poolFeatures: PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    receive() external payable {}
}

contract V4RouterSimple {
    IPoolManager immutable POOL_MANAGER_V4;

    constructor(IPoolManager _manager) {
        POOL_MANAGER_V4 = _manager;
    }

    function unlockCallback(bytes calldata data) public returns (bytes memory) {
        (uint256 action, bytes memory _data) = abi.decode(data, (uint256, bytes));

        if (action == 0) {
            (
                address caller,
                PoolKey memory key,
                int24 tickLower,
                int24 tickUpper,
                int256 liquidity
            ) = abi.decode(_data, (address, PoolKey, int24, int24, int256));
            (int256 delta0, int256 delta1) = modifyLiquidity(
                caller,
                key,
                tickLower,
                tickUpper,
                liquidity
            );
            return abi.encode(delta0, delta1);
        } else if (action == 1) {
            (address caller, PoolKey memory key, uint160 sqrtPriceX96) = abi.decode(
                _data,
                (address, PoolKey, uint160)
            );
            swapTo(caller, key, sqrtPriceX96);
            return "";
        } else if (action == 2) {
            (address caller, PoolKey memory key, int256 amountSpecified, bool zeroForOne) = abi
                .decode(_data, (address, PoolKey, int256, bool));
            (int256 delta0, int256 delta1) = swap(caller, key, amountSpecified, zeroForOne);
            return abi.encode(delta0, delta1);
        } else if (action == 3) {
            (
                address caller,
                PoolKey memory key,
                int24 tickLower,
                int24 tickUpper,
                int256 liquidity,
                bytes32 salt
            ) = abi.decode(_data, (address, PoolKey, int24, int24, int256, bytes32));
            modifyLiquidityWithSalt(caller, key, tickLower, tickUpper, liquidity, salt);
            return "";
        } else if (action == 4) {
            (address caller, Currency currency, uint256 amount) = abi.decode(
                _data,
                (address, Currency, uint256)
            );
            mintCurrency(caller, currency, amount);
            return "";
        } else if (action == 5) {
            (address caller, Currency currency, uint256 amount) = abi.decode(
                _data,
                (address, Currency, uint256)
            );
            burnCurrency(caller, currency, amount);
            return "";
        }

        return "";
    }

    function mintCurrency(address caller, Currency currency, uint256 amount) public payable {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            POOL_MANAGER_V4.unlock(abi.encode(4, abi.encode(msg.sender, currency, amount)));
            return;
        }
        POOL_MANAGER_V4.sync(currency);
        if (!currency.isAddressZero()) {
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(currency),
                caller,
                address(POOL_MANAGER_V4),
                amount
            );
            POOL_MANAGER_V4.settle();
        } else {
            POOL_MANAGER_V4.settle{value: amount}();
        }
        POOL_MANAGER_V4.mint(caller, uint160(Currency.unwrap(currency)), amount);
    }

    function burnCurrency(address caller, Currency currency, uint256 amount) public {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            POOL_MANAGER_V4.unlock(abi.encode(5, abi.encode(msg.sender, currency, amount)));
            return;
        }
        POOL_MANAGER_V4.burn(caller, uint160(Currency.unwrap(currency)), amount);
        POOL_MANAGER_V4.take(currency, caller, uint128(amount));
    }

    function modifyLiquidity(
        address caller,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity
    ) public payable returns (int256, int256) {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            bytes memory res = POOL_MANAGER_V4.unlock(
                abi.encode(0, abi.encode(msg.sender, key, tickLower, tickUpper, liquidity))
            );
            return abi.decode(res, (int256, int256));
        }

        (BalanceDelta delta, ) = POOL_MANAGER_V4.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidity, bytes32(0)),
            ""
        );

        if (delta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            if (!key.currency0.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency0),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint128(-delta.amount0())
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint128(-delta.amount0())}();
            }
        } else if (delta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            if (!key.currency1.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency1),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint128(-delta.amount1())
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint128(-delta.amount1())}();
            }
        } else if (delta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(delta.amount1()));
        }

        return (delta.amount0(), delta.amount1());
    }

    function modifyLiquidityWithSalt(
        address caller,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes32 salt
    ) public payable {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            POOL_MANAGER_V4.unlock(
                abi.encode(3, abi.encode(msg.sender, key, tickLower, tickUpper, liquidity, salt))
            );
            return;
        }

        (BalanceDelta delta, ) = POOL_MANAGER_V4.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidity, salt),
            ""
        );

        if (delta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            if (!key.currency0.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency0),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint128(-delta.amount0())
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint128(-delta.amount0())}();
            }
        } else if (delta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(delta.amount0()));
        }

        if (delta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            if (!key.currency1.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency1),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint128(-delta.amount1())
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint128(-delta.amount1())}();
            }
        } else if (delta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(delta.amount1()));
        }
    }

    function swap(
        address caller,
        PoolKey memory key,
        int256 amountSpecified,
        bool zeroForOne
    ) public payable returns (int256, int256) {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            bytes memory res = POOL_MANAGER_V4.unlock(
                abi.encode(2, abi.encode(msg.sender, key, amountSpecified, zeroForOne))
            );
            return abi.decode(res, (int256, int256));
        }

        BalanceDelta swapDelta = POOL_MANAGER_V4.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -amountSpecified,
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            ),
            ""
        );

        if (swapDelta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            if (!key.currency0.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency0),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint256(-int256(swapDelta.amount0()))
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint256(-int256(swapDelta.amount0()))}();
            }
        } else if (swapDelta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(swapDelta.amount0()));
        }

        if (swapDelta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            if (!key.currency1.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency1),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint256(-int256(swapDelta.amount1()))
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint256(-int256(swapDelta.amount1()))}();
            }
        } else if (swapDelta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(swapDelta.amount1()));
        }

        return (swapDelta.amount0(), swapDelta.amount1());
    }

    function swapTo(address caller, PoolKey memory key, uint160 sqrtPriceX96) public payable {
        if (msg.sender != address(POOL_MANAGER_V4)) {
            bool done;
            // we can only swap type(int128).max tokens at one time, so we need to loop until the price is set
            while (!done) {
                POOL_MANAGER_V4.unlock(abi.encode(1, abi.encode(msg.sender, key, sqrtPriceX96)));
                done = V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, key.toId()) == sqrtPriceX96;
            }
            return;
        }
        uint160 sqrtPriceX96Before = V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, key.toId());

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        bool zeroForOne = sqrtPriceX96Before > sqrtPriceX96;

        BalanceDelta swapDelta = POOL_MANAGER_V4.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, type(int128).min + 1, sqrtPriceX96),
            ""
        );

        if (swapDelta.amount0() < 0) {
            POOL_MANAGER_V4.sync(key.currency0);
            if (!key.currency0.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency0),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint256(-int256(swapDelta.amount0()))
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint256(-int256(swapDelta.amount0()))}();
            }
        } else if (swapDelta.amount0() > 0) {
            POOL_MANAGER_V4.take(key.currency0, caller, uint128(swapDelta.amount0()));
        }

        if (swapDelta.amount1() < 0) {
            POOL_MANAGER_V4.sync(key.currency1);
            if (!key.currency1.isAddressZero()) {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(key.currency1),
                    caller,
                    address(POOL_MANAGER_V4),
                    uint256(-int256(swapDelta.amount1()))
                );
                POOL_MANAGER_V4.settle();
            } else {
                POOL_MANAGER_V4.settle{value: uint256(-int256(swapDelta.amount1()))}();
            }
        } else if (swapDelta.amount1() > 0) {
            POOL_MANAGER_V4.take(key.currency1, caller, uint128(swapDelta.amount1()));
        }
    }
}

contract PriceFlipAdapterTest is Test, PositionUtils {
    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);

    // the instance of SFPM we are testing
    SemiFungiblePositionManager sfpm;

    // reference implementations used by the factory
    address poolReference;
    address collateralReference;

    // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    PanopticFactory factory;
    PanopticPool pp;
    CollateralTracker ct0;
    CollateralTracker ct1;
    PanopticHelper ph;

    IPoolManager manager;
    V4RouterSimple routerV4;
    PoolKey poolKey;

    IUniswapV3Pool uniPool;
    ERC20S WETH;
    ERC20S USDC;
    SwapperC swapperc;

    PriceFlipAdapter adapter;
    PriceFlipAdapterFactory adapterFactory;

    function setUp() public {
        vm.startPrank(Deployer);

        manager = IPoolManager(address(new PoolManager(address(0))));
        routerV4 = new V4RouterSimple(manager);
        sfpm = new SemiFungiblePositionManager(manager, 10 ** 13, 10 ** 13, 0);
        ph = new PanopticHelper(sfpm);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(sfpm, manager));
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20, manager)
        );

        // Create WETH and USDC tokens, ensuring USDC's address is alphanumerically less than WETH's
        USDC = new ERC20S("USDC", "USDC", 6);
        WETH = new ERC20S("WETH", "WETH", 18);

        // Check if we need to swap the token variables to ensure USDC address < WETH address
        if (address(USDC) > address(WETH)) {
            (USDC, WETH) = (WETH, USDC);
        }

        // Create Uniswap V3 pool with USDC and WETH (now guaranteed to be in correct order)
        uniPool = IUniswapV3Pool(V3FACTORY.createPool(address(USDC), address(WETH), 500));

        // Create V4 pool key with ETH (native) and USDC
        poolKey = PoolKey(
            Currency.wrap(address(0)), // ETH (native)
            Currency.wrap(address(USDC)),
            500,
            10,
            IHooks(address(0))
        );

        // Deploy PriceFlipAdapter factory and create adapter for the V3 pool
        adapterFactory = new PriceFlipAdapterFactory();
        adapter = adapterFactory.deploy(IV3CompatibleOracle(address(uniPool)));

        // Setup swapper
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        USDC.mint(Swapper, type(uint248).max);
        WETH.mint(Swapper, type(uint248).max);
        USDC.approve(address(swapperc), type(uint248).max);
        WETH.approve(address(swapperc), type(uint248).max);
        USDC.approve(address(routerV4), type(uint248).max);
        WETH.approve(address(routerV4), type(uint248).max);
        vm.deal(Swapper, type(uint248).max);

        // Initialize V3 pool at price = 1
        IUniswapV3Pool(uniPool).initialize(2 ** 96);
        IUniswapV3Pool(uniPool).increaseObservationCardinalityNext(100);

        // Generate 100 observations at price = 2
        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96 * 2); // First set price to 2
        vm.stopPrank();

        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(block.timestamp + 1);
            vm.roll(block.number + 1);
            vm.startPrank(Swapper);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            vm.stopPrank();
        }

        // Initialize V4 pool
        manager.initialize(poolKey, 2 ** 96);

        // Create Panoptic pool using the adapter as oracle
        factory = new PanopticFactory(
            sfpm,
            manager,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        USDC.mint(Deployer, type(uint104).max);
        WETH.mint(Deployer, type(uint104).max);
        USDC.approve(address(factory), type(uint104).max);
        WETH.approve(address(factory), type(uint104).max);

        pp = PanopticPool(
            address(
                factory.deployNewPool(
                    IV3CompatibleOracle(address(adapter)),
                    poolKey,
                    uint96(block.timestamp)
                )
            )
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo{value: 1 ether}(address(0), poolKey, 2 ** 96);
        vm.stopPrank();

        // Update median
        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeMedian();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        vm.deal(Alice, type(uint128).max);
        vm.deal(Bob, type(uint128).max);

        // Fund accounts
        vm.startPrank(Alice);
        USDC.mint(Alice, type(uint104).max);
        USDC.approve(address(ct0), type(uint104).max);
        USDC.approve(address(ct1), type(uint104).max);
        ct0.deposit{value: type(uint104).max}(type(uint104).max, Alice);
        ct1.deposit{value: type(uint104).max}(type(uint104).max, Alice);
        vm.stopPrank();

        vm.startPrank(Bob);
        USDC.mint(Bob, type(uint104).max);
        USDC.approve(address(ct0), type(uint104).max);
        USDC.approve(address(ct1), type(uint104).max);
        ct0.deposit{value: type(uint104).max}(type(uint104).max, Bob);
        ct1.deposit{value: type(uint104).max}(type(uint104).max, Bob);
        vm.stopPrank();
    }

    function test_slot0_flips_price_and_tick() public {
        // Swap to a non-1 price in V3 pool
        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96 * 2); // Price = 2
        vm.stopPrank();

        // Get slot0 from V3 pool and adapter
        (
            uint160 sqrtPriceX96V3,
            int24 tickV3,
            uint16 observationIndexV3,
            uint16 observationCardinalityV3,
            uint16 observationCardinalityNextV3,
            uint8 feeProtocolV3,
            bool unlockedV3
        ) = uniPool.slot0();

        (
            uint160 sqrtPriceX96Adapter,
            int24 tickAdapter,
            uint16 observationIndexAdapter,
            uint16 observationCardinalityAdapter,
            uint16 observationCardinalityNextAdapter,
            uint8 feeProtocolAdapter,
            bool unlockedAdapter
        ) = adapter.slot0();

        // Verify price is flipped (1/price)
        assertEq(sqrtPriceX96Adapter, uint160(uint256(2 ** 192) / sqrtPriceX96V3));
        // Verify tick is negated
        assertEq(tickAdapter, -tickV3);
        // Verify other parameters remain unchanged
        assertEq(observationIndexAdapter, observationIndexV3);
        assertEq(observationCardinalityAdapter, observationCardinalityV3);
        assertEq(observationCardinalityNextAdapter, observationCardinalityNextV3);
        assertEq(feeProtocolAdapter, feeProtocolV3);
        assertEq(unlockedAdapter, unlockedV3);
    }

    function test_observations_negates_tickCumulative() public {
        // Take 100 price observations by advancing time and swapping
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            vm.startPrank(Swapper);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            vm.stopPrank();
        }

        // Check observations from V3 pool and adapter
        for (uint256 i = 0; i < 10; i++) {
            (
                uint32 blockTimestampV3,
                int56 tickCumulativeV3,
                uint160 secondsPerLiquidityCumulativeX128V3,
                bool initializedV3
            ) = uniPool.observations(i);

            (
                uint32 blockTimestampAdapter,
                int56 tickCumulativeAdapter,
                uint160 secondsPerLiquidityCumulativeX128Adapter,
                bool initializedAdapter
            ) = adapter.observations(i);

            // Verify timestamps and initialization status remain unchanged
            assertEq(blockTimestampAdapter, blockTimestampV3);
            assertEq(initializedAdapter, initializedV3);
            // Verify tickCumulative is negated
            assertEq(tickCumulativeAdapter, -tickCumulativeV3);
            // Verify secondsPerLiquidityCumulative remains unchanged
            assertEq(secondsPerLiquidityCumulativeX128Adapter, secondsPerLiquidityCumulativeX128V3);
        }
    }

    function test_observe_negates_tickCumulative() public {
        // Take 100 price observations by advancing time and swapping
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            vm.startPrank(Swapper);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            vm.stopPrank();
        }

        // Create array of secondsAgos for observation
        uint32[] memory secondsAgos = new uint32[](5);
        secondsAgos[0] = 0;
        secondsAgos[1] = 60;
        secondsAgos[2] = 120;
        secondsAgos[3] = 180;
        secondsAgos[4] = 240;

        // Get observations from V3 pool and adapter
        (
            int56[] memory tickCumulativesV3,
            uint160[] memory secondsPerLiquidityCumulativeX128sV3
        ) = uniPool.observe(secondsAgos);

        (
            int56[] memory tickCumulativesAdapter,
            uint160[] memory secondsPerLiquidityCumulativeX128sAdapter
        ) = adapter.observe(secondsAgos);

        // Verify all tickCumulatives are negated
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            assertEq(tickCumulativesAdapter[i], -tickCumulativesV3[i]);
            assertEq(
                secondsPerLiquidityCumulativeX128sAdapter[i],
                secondsPerLiquidityCumulativeX128sV3[i]
            );
        }
    }

    function test_increaseObservationCardinalityNext() public {
        // Get initial cardinality
        (, , , , uint16 cardinalityNextBefore, , ) = uniPool.slot0();

        // Increase cardinality through adapter
        uint16 newCardinality = cardinalityNextBefore + 10;
        adapter.increaseObservationCardinalityNext(newCardinality);

        // Verify cardinality was increased
        (, , , , uint16 cardinalityNextAfter, , ) = uniPool.slot0();
        assertEq(cardinalityNextAfter, newCardinality);
    }

    function test_liquidate_100p_protocolLoss() public {
        vm.startPrank(Alice);

        // Create position
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(0).addPoolId(sfpm.getPoolId(poolKey.toId())).addLeg(
            0,
            1,
            1,
            0,
            1,
            0,
            -15,
            1
        );

        // Mint options
        pp.mintOptions(
            posIdList,
            1_003_003,
            0,
            Constants.MAX_V4POOL_TICK,
            Constants.MIN_V4POOL_TICK,
            true
        );

        // Swap to extreme price
        vm.startPrank(Swapper);
        routerV4.swapTo{value: 1 ether}(address(0), poolKey, Math.getSqrtRatioAtTick(-800_000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(800_000));
        vm.stopPrank();

        // Take 100 observations
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 10);
            vm.startPrank(Swapper);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 10);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 10);
            vm.stopPrank();
        }

        editCollateral(ct0, Alice, 1000);
        editCollateral(ct1, Alice, 0);

        // Liquidate position
        vm.startPrank(Charlie);
        pp.liquidate(new TokenId[](0), Alice, posIdList);
        vm.stopPrank();
    }
}
