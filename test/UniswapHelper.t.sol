// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
import {Constants} from "@libraries/Constants.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPoint128} from "v3-core/libraries/FixedPoint128.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
import {PositionKey} from "v3-periphery/libraries/PositionKey.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {UniswapHelper} from "../src/UniswapHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionUtils} from "lib/panoptic-v1-core/test/foundry/testUtils/PositionUtils.sol";
import {UniPoolPriceMock} from "lib/panoptic-v1-core/test/foundry/testUtils/PriceMocks.sol";
import {Pointer} from "@types/Pointer.sol";

contract SemiFungiblePositionManagerHarness is SemiFungiblePositionManager {
    constructor(IUniswapV3Factory _factory) SemiFungiblePositionManager(_factory) {}

    function poolContext(uint64 poolId) public view returns (PoolAddressAndLock memory) {
        return s_poolContext[poolId];
    }

    function addrToPoolId(address pool) public view returns (uint256) {
        return s_AddrToPoolIdData[pool];
    }
}

contract UniswapHelperTest is PositionUtils {
    /*//////////////////////////////////////////////////////////////
                           MAINNET CONTRACTS
    //////////////////////////////////////////////////////////////*/

    console2.log('foo2');
    // the instance of SFPM we are testing
    SemiFungiblePositionManagerHarness sfpm;

    // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Mainnet router address - used for swaps to test fees/premia
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // used as example of price parity
    IUniswapV3Pool constant USDC_USDT_5 =
        IUniswapV3Pool(0x7858E59e0C01EA06Df3aF3D20aC7B0003275D4Bf);

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
    IUniswapV3Pool constant USDC_WETH_30 =
        IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
    IUniswapV3Pool[3] public pools = [USDC_WETH_5, WBTC_ETH_30, USDC_WETH_30];

    /*//////////////////////////////////////////////////////////////
                              WORLD STATE
    //////////////////////////////////////////////////////////////*/

    // store some data about the pool we are testing
    IUniswapV3Pool pool;
    uint64 poolId;
    address token0;
    address token1;
    // We range position size in terms of WETH, so need to figure out which token is WETH
    uint256 isWETH;
    uint24 fee;
    int24 tickSpacing;
    uint160 currentSqrtPriceX96;
    int24 currentTick;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint256 poolBalance0;
    uint256 poolBalance1;

    int24 medianTick;
    int24 TWAPtick;

    UniswapHelper uh;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);
    address Seller = address(0x12345678912);

    /*//////////////////////////////////////////////////////////////
                               TEST DATA
    //////////////////////////////////////////////////////////////*/

    // used to pass into libraries
    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtLower;
    uint160 sqrtUpper;

    int24 atTick;

    /*//////////////////////////////////////////////////////////////
                               ENV SETUP
    //////////////////////////////////////////////////////////////*/

    function _initPool(uint256 seed) internal {
        _initWorld(seed);
    }

    function _initWorldAtTick(uint256 seed, int24 tick) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        // replace pool with a mock and set the tick
        vm.etch(address(pool), address(new UniPoolPriceMock()).code);

        UniPoolPriceMock(address(pool)).construct(
            UniPoolPriceMock.Slot0(TickMath.getSqrtRatioAtTick(tick), tick, 0, 0, 0, 0, true),
            address(token0),
            address(token1),
            fee,
            tickSpacing
        );

        _initAccounts();
    }

    function _initWorld(uint256 seed) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        _initAccounts();
    }

    function _cacheWorldState(IUniswapV3Pool _pool) internal {
        pool = _pool;
        poolId = PanopticMath.getPoolId(address(_pool));
        token0 = _pool.token0();
        token1 = _pool.token1();
        isWETH = token0 == address(WETH) ? 0 : 1;
        fee = _pool.fee();
        tickSpacing = _pool.tickSpacing();
        (currentSqrtPriceX96, currentTick, , , , , ) = _pool.slot0();
        feeGrowthGlobal0X128 = _pool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = _pool.feeGrowthGlobal1X128();
        poolBalance0 = IERC20Partial(token0).balanceOf(address(_pool));
        poolBalance1 = IERC20Partial(token1).balanceOf(address(_pool));
    }

    function _initAccounts() internal {
        vm.startPrank(Swapper);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        deal(token0, Swapper, type(uint104).max);
        deal(token1, Swapper, type(uint104).max);

        vm.startPrank(Charlie);

        deal(token0, Charlie, type(uint104).max);
        deal(token1, Charlie, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        vm.startPrank(Seller);

        deal(token0, Seller, type(uint104).max);
        deal(token1, Seller, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        vm.startPrank(Bob);
        // account for MEV tax
        deal(token0, Bob, (type(uint104).max * uint256(1010)) / 1000);
        deal(token1, Bob, (type(uint104).max * uint256(1010)) / 1000);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        vm.startPrank(Alice);

        deal(token0, Alice, type(uint104).max);
        deal(token1, Alice, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

    }

    function setUp() public {
        console2.log('foo');
        sfpm = new SemiFungiblePositionManagerHarness(V3FACTORY);
        console2.log('bar');
        uh = new UniswapHelper(SemiFungiblePositionManager(sfpm));

    }

    // bounds the input value between 2**min and 2**(max+1)-1
    function boundLog(uint256 value, uint8 min, uint8 max) internal returns (uint256) {
        uint256 range = uint256(max) - uint256(min) + 1;
        uint256 m0 = min + (value % range);
        value = uint256(keccak256(abi.encode(value)));
        uint256 m1 = value % 2 ** max;
        return 2 ** m0 + (m1 >> (max - m0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     BOUND LOG
    //////////////////////////////////////////////////////////////////////////*/

    function test_boundLog() public {
        for (uint256 i = 0; i <= 255; ++i) {
            assertEq(
                boundLog(0, uint8(0), uint8(i)),
                2 ** 0 + ((uint256(keccak256(abi.encode(uint256(0)))) % 2 ** i) >> i)
            );

            assertEq(
                boundLog(0, uint8(i), uint8(255)),
                2 ** i + ((uint256(keccak256(abi.encode(uint256(0)))) % 2 ** 255) >> (255 - i))
            );

            assertEq(
                boundLog(0, uint8(i), uint8(i)),
                2 ** i + (uint256(keccak256(abi.encode(uint256(0)))) % 2 ** i)
            );
        }
    }

    /// forge-config: default.fuzz.runs = 100000
    function test_boundLog(uint256 x, uint8 min, uint8 max) public {
        if (min > max) (min, max) = (max, min);

        uint256 result = boundLog(x, min, max);

        assertGe(result, 2 ** min);
        assertLe(result, max == 255 ? type(uint256).max : 2 ** (max + 1) - 1);
        assertEq(result, boundLog(x, min, max));
    }

    /// forge-config: default.fuzz.runs = 1000
    function test_Success_boundLog_sameLimits(uint256 x) public {
        for (uint8 i; i < 255; ++i) {
            x = uint256(keccak256(abi.encode(x)));
            uint256 b = boundLog(x, i, i);

            assertTrue(b >= 2 ** i);
            assertTrue(b <= (2 ** (i + 1) - 1));
        }
        x = uint256(keccak256(abi.encode(x)));
        uint256 b = boundLog(x, 255, 255);

        assertTrue(b >= 2 ** 255);
        assertTrue(b <= (type(uint256).max));
    }

    /// forge-config: default.fuzz.runs = 1000
    function test_Success_boundLog_low(uint256 x) public {
        for (uint8 i; i < 255; ++i) {
            x = uint256(keccak256(abi.encode(x)));
            uint256 b = boundLog(x, 0, i);

            assertTrue(b >= 2 ** 0);
            assertTrue(b <= (2 ** (i + 1) - 1));
        }
        x = uint256(keccak256(abi.encode(x)));
        uint256 b = boundLog(x, 0, 255);

        assertTrue(b >= 2 ** 0);
        assertTrue(b <= (type(uint256).max));
    }

    /// forge-config: default.fuzz.runs = 1000
    function test_Success_boundLog_high(uint256 x) public {
        for (uint8 i; i < 255; ++i) {
            x = uint256(keccak256(abi.encode(x)));
            uint256 b = boundLog(x, i, 255);

            assertTrue(b >= 2 ** i);
            assertTrue(b <= type(uint256).max);
        }
        x = uint256(keccak256(abi.encode(x)));
        uint256 b = boundLog(x, 255, 255);

        assertTrue(b >= 2 ** 255);
        assertTrue(b <= (type(uint256).max));
    }

    function test_getTickData() public {
        _initPool(1);

        console2.log(uh.plotPoolLiquidity(address(pool), 1));
    }

    function test_getSVG() public {
        int256[] memory tickData = new int256[](8);
        tickData[0] = 10;
        tickData[1] = 15;
        tickData[2] = 20;
        tickData[3] = 25;
        tickData[4] = 30;
        tickData[5] = 35;
        tickData[6] = 40;
        tickData[7] = 45;

        int256[] memory liquidityData = new int256[](8);
        liquidityData[0] = 5;
        liquidityData[1] = 7;
        liquidityData[2] = 25;
        liquidityData[3] = 10;
        liquidityData[4] = 9;
        liquidityData[5] = 20;
        liquidityData[6] = 12;
        liquidityData[7] = 6;

        console2.log(uh.generateBase64EncodedSVG(tickData, liquidityData, 17, 1,''));
    }

    function test_toStringSignedPct() public {

        assertEq(uh.toStringSignedPct(int256(10)), "0.10");
        assertEq(uh.toStringSignedPct(int256(-10)), "-0.10");
    
        assertEq(uh.toStringSignedPct(int256(123321)), "1233.21");
        assertEq(uh.toStringSignedPct(int256(-321123)), "-3211.23");
        
        assertEq(uh.toStringSignedPct(int256(123301)), "1233.01");
        assertEq(uh.toStringSignedPct(int256(-321103)), "-3211.03");
   

    }
}
