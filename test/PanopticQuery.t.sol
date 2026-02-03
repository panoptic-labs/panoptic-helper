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
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactoryV4.sol";
import {PanopticQuery} from "../src/PanopticQuery.sol";
import {TokenIdHelper} from "../src/TokenIdHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionUtils} from "lib/panoptic-v2-core/test/foundry/testUtils/PositionUtils.sol";
import {UniPoolPriceMock} from "lib/panoptic-v2-core/test/foundry/testUtils/PriceMocks.sol";
import {Pointer} from "@types/Pointer.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract SemiFungiblePositionManagerHarness is SemiFungiblePositionManager {
    constructor(
        IPoolManager _manager
    ) SemiFungiblePositionManager(_manager, 10 ** 13, 10 ** 13, 0) {}
}

contract PanopticPoolHarness is PanopticPool {
    /// @notice get the positions hash of an account
    /// @param user the account to get the positions hash of
    /// @return _positionsHash positions hash of the account
    function positionsHash(address user) external view returns (uint248 _positionsHash) {
        _positionsHash = uint248(s_positionsHash[user]);
    }

    constructor(ISemiFungiblePositionManager _sfpm) PanopticPool(_sfpm) {}
}

contract PanopticQueryTest is PositionUtils {
    /*//////////////////////////////////////////////////////////////
                           MAINNET CONTRACTS
    //////////////////////////////////////////////////////////////*/

    // the instance of SFPM we are testing
    SemiFungiblePositionManagerHarness sfpm;
    IRiskEngine re;
    uint256 vegoid = 4;
    IPoolManager manager;

    PoolKey poolKey;
    // A TokenIdHelper for getting equivalent token IDs as need be
    TokenIdHelper tih;

    // reference implemenatations used by the factory
    address poolReference;

    address collateralReference;

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

    PanopticFactory factory;
    PanopticPoolHarness pp;
    PanopticQuery pq;
    CollateralTracker ct0;
    CollateralTracker ct1;

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
    mapping(TokenId tokenId => uint256 balance) userBalance;

    mapping(address actor => uint256 lastBalance0) lastCollateralBalance0;
    mapping(address actor => uint256 lastBalance1) lastCollateralBalance1;

    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtLower;
    uint160 sqrtUpper;

    uint128 positionSize;
    uint128 positionSizeBurn;

    uint128 expectedLiq;
    uint128 expectedLiqMint;
    uint128 expectedLiqBurn;

    int256 $amount0Moved;
    int256 $amount1Moved;
    int256 $amount0MovedMint;
    int256 $amount1MovedMint;
    int256 $amount0MovedBurn;
    int256 $amount1MovedBurn;

    int128 $expectedPremia0;
    int128 $expectedPremia1;

    int24[] tickLowers;
    int24[] tickUppers;
    uint160[] sqrtLowers;
    uint160[] sqrtUppers;

    uint128[] positionSizes;
    uint128[] positionSizesBurn;

    uint128[] expectedLiqs;
    uint128[] expectedLiqsMint;
    uint128[] expectedLiqsBurn;

    int24 $width;
    int24 $strike;
    int24 $width2;
    int24 $strike2;

    uint256[] tokenIds;

    int256[] $amount0Moveds;
    int256[] $amount1Moveds;
    int256[] $amount0MovedsMint;
    int256[] $amount1MovedsMint;
    int256[] $amount0MovedsBurn;
    int256[] $amount1MovedsBurn;

    int128[] $expectedPremias0;
    int128[] $expectedPremias1;

    int256 $swap0;
    int256 $swap1;
    int256 $itm0;
    int256 $itm1;
    int256 $intrinsicValue0;
    int256 $intrinsicValue1;
    int256 $ITMSpread0;
    int256 $ITMSpread1;

    int256 $balanceDelta0;
    int256 $balanceDelta1;

    LeftRightUnsigned tokenData0;
    LeftRightUnsigned tokenData1;

    uint256 collateralBalance;
    uint256 requiredCollateral;

    uint256 calculatedCollateralBalance;
    uint256 calculatedRequiredCollateral;

    int24 atTick;

    TokenId positionSolo;

    function mintOptions(
        PanopticPool pp,
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint24 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory mintList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        TokenId tokenId = positionIdList[positionIdList.length - 1];
        sizeList[0] = positionSize;
        mintList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(effectiveLiquidityLimitX32));

        pp.dispatch(mintList, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
    }

    function burnOptions(
        PanopticPoolHarness pp,
        TokenId tokenId,
        TokenId[] memory positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory burnList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        sizeList[0] = 0;
        burnList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(type(uint24).max / 2));
        pp.dispatch(burnList, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
    }

    function _assertScanEntryMatchesSFPM(
        bytes memory poolKey,
        address account,
        int24 tl,
        int24 tu,
        uint256 idx,
        uint128[2][] memory net,
        uint128[2][] memory removed
    ) internal view {
        LeftRightUnsigned liq0 = sfpm.getAccountLiquidity(poolKey, account, 0, tl, tu);
        LeftRightUnsigned liq1 = sfpm.getAccountLiquidity(poolKey, account, 1, tl, tu);

        assertEq(net[idx][0], liq0.rightSlot(), "scan net0 mismatch");
        assertEq(removed[idx][0], liq0.leftSlot(), "scan removed0 mismatch");

        assertEq(net[idx][1], liq1.rightSlot(), "scan net1 mismatch");
        assertEq(removed[idx][1], liq1.leftSlot(), "scan removed1 mismatch");
    }

    function _findStrike(int24[] memory strikes, int24 target) internal pure returns (uint256) {
        for (uint256 i; i < strikes.length; ++i) {
            if (strikes[i] == target) return i;
        }
        return type(uint256).max;
    }

    function _min24(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    function _max24(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

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

        _deployPanopticPool();

        _initAccounts();
    }

    function _initWorld(uint256 seed) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        _deployPanopticPool();

        _initAccounts();
    }

    function _cacheWorldState(IUniswapV3Pool _pool) internal {
        pool = _pool;
        poolId = sfpm.getPoolId(abi.encode(address(_pool)), 0); // vegoid = 0 for tests
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
        poolKey = PoolKey(
            Currency.wrap(token0),
            Currency.wrap(token1),
            fee,
            tickSpacing,
            IHooks(address(0))
        );
        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(_pool.tickSpacing())) << 48;
        }
    }

    function _deployPanopticPool() internal {
        vm.startPrank(Deployer);

        // Provide tokens to the manager and initialize the pool in the v4 PoolManager
        deal(token0, address(manager), type(uint128).max);
        deal(token1, address(manager), type(uint128).max);
        manager.initialize(poolKey, currentSqrtPriceX96);

        factory = new PanopticFactory(
            sfpm,
            manager,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        re = IRiskEngine(address(new RiskEngine(10_000_000, 10_000_000, address(0), address(0))));

        deal(token0, Deployer, type(uint104).max);
        deal(token1, Deployer, type(uint104).max);
        IERC20Partial(token0).approve(address(factory), type(uint104).max);
        IERC20Partial(token1).approve(address(factory), type(uint104).max);

        pp = PanopticPoolHarness(
            address(factory.deployNewPool(poolKey, re, uint96(block.timestamp)))
        );

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
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
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        vm.startPrank(Seller);

        deal(token0, Seller, type(uint104).max);
        deal(token1, Seller, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Seller);
        ct1.deposit(type(uint104).max, Seller);

        // cancel out MEV tax and push exchange rate back to 1
        deal(address(ct0), Seller, type(uint104).max, true);
        deal(address(ct1), Seller, type(uint104).max, true);

        vm.startPrank(Bob);
        // account for MEV tax
        deal(token0, Bob, (type(uint104).max * uint256(1010)) / 1000);
        deal(token1, Bob, (type(uint104).max * uint256(1010)) / 1000);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Bob);
        ct1.deposit(type(uint104).max, Bob);

        // cancel out MEV tax and push exchange rate back to 1
        deal(address(ct0), Bob, type(uint104).max, true);
        deal(address(ct1), Bob, type(uint104).max, true);

        vm.startPrank(Alice);

        deal(token0, Alice, type(uint104).max);
        deal(token1, Alice, type(uint104).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);
        IERC20Partial(token0).approve(address(pp), type(uint256).max);
        IERC20Partial(token1).approve(address(pp), type(uint256).max);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Alice);
        ct1.deposit(type(uint104).max, Alice);

        // cancel out MEV tax and push exchange rate back to 1
        deal(address(ct0), Alice, type(uint104).max, true);
        deal(address(ct1), Alice, type(uint104).max, true);
    }

    function setUp() public {
        manager = new PoolManager(address(0));
        sfpm = new SemiFungiblePositionManagerHarness(manager);

        pq = new PanopticQuery(ISemiFungiblePositionManager(address(sfpm)));
        tih = new TokenIdHelper(ISemiFungiblePositionManager(address(sfpm)));

        poolReference = address(
            new PanopticPoolHarness(ISemiFungiblePositionManager(address(sfpm)))
        );
        collateralReference = address(new CollateralTracker(10));
    }

    /*//////////////////////////////////////////////////////////////
                          TEST DATA POPULATION
    //////////////////////////////////////////////////////////////*/

    function populatePositionData(
        int24[2] memory width,
        int24[2] memory strike,
        uint256[2] memory positionSizeSeeds
    ) internal {
        tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
        tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

        tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
        tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
        sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
        sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

        // 0.0001 -> 10_000 WETH
        positionSizeSeeds[0] = bound(positionSizeSeeds[0], 10 ** 15, 10 ** 22);
        positionSizeSeeds[1] = bound(positionSizeSeeds[1], 10 ** 15, 10 ** 22);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLowers[0],
                    tickUppers[0],
                    isWETH,
                    positionSizeSeeds[0]
                )
            )
        );

        positionSizes.push(
            uint128(
                getContractsForAmountAtTick(
                    currentTick,
                    tickLowers[1],
                    tickUppers[1],
                    isWETH,
                    positionSizeSeeds[1]
                )
            )
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding
        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSizes[0]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[0],
                    sqrtUppers[0],
                    positionSizes[0]
                )
        );

        expectedLiqs.push(
            isWETH == 0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[1]
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtLowers[1],
                    sqrtUppers[1],
                    positionSizes[1]
                )
        );
    }

    // returns token containing 'totalLegs' amount of legs
    // i.e totalLegs of 1 has a tokenId with 1 legs
    // uses a seed to fuzz data so that there is different data for each leg
    function fuzzedPosition(
        uint256 totalLegs,
        uint256 optionRatioSeed,
        uint256 assetSeed,
        uint256 isLongSeed,
        uint256 tokenTypeSeed,
        int256 strikeSeed,
        int256 widthSeed
    ) internal returns (TokenId) {
        TokenId tokenId = TokenId.wrap(uint256(poolId));

        for (uint256 legIndex; legIndex < totalLegs; legIndex++) {
            // We don't want the same data for each leg
            // int divide each seed by the current legIndex
            // gives us a pseudorandom seed
            // forge bound does not randomize the output
            {
                uint256 randomizer = legIndex + 1;

                optionRatioSeed = optionRatioSeed / randomizer;
                assetSeed = assetSeed / randomizer;
                isLongSeed = isLongSeed / randomizer;
                tokenTypeSeed = tokenTypeSeed / randomizer;
                strikeSeed = strikeSeed / int24(int256(randomizer));
                widthSeed = widthSeed / int24(int256(randomizer));
            }

            {
                // the following are all 1 bit so mask them:
                uint16 MASK = 0x1; // takes first 1 bit of the uint16
                assetSeed = assetSeed & MASK;
                isLongSeed = isLongSeed & MASK;
                tokenTypeSeed = tokenTypeSeed & MASK;
            }

            /// bound inputs
            int24 strike;
            int24 width;
            {
                // the following must be at least 1
                optionRatioSeed = bound(optionRatioSeed, 1, 127);

                width = int24(bound(widthSeed, 1, 4094));
                int24 oneSidedRange = (width * tickSpacing) / 2;

                (int24 strikeOffset, int24 minTick, int24 maxTick) = PositionUtils.getContextFull(
                    uint256(uint24(tickSpacing)),
                    currentTick,
                    width
                );

                int24 lowerBound = int24(minTick + oneSidedRange - strikeOffset);
                int24 upperBound = int24(maxTick - oneSidedRange - strikeOffset);

                // Set current tick and pool price
                currentTick = int24(bound(currentTick, minTick, maxTick));
                currentSqrtPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);

                // bound strike
                strike = int24(
                    bound(strikeSeed, lowerBound / tickSpacing, upperBound / tickSpacing)
                );
                strike = int24(strike * tickSpacing + strikeOffset);
            }

            {
                // add a leg
                // no risk partner by default (will reference its own leg index)
                tokenId = tokenId.addLeg(
                    legIndex,
                    optionRatioSeed,
                    assetSeed,
                    isLongSeed,
                    tokenTypeSeed,
                    legIndex,
                    strike,
                    width
                );
            }
        }

        return tokenId;
    }

    function test_Success_checkCollateral_LiquidationPrices(uint256 x) public {
        _initPool(x);

        uint256 positionSizeSeed = 1e18;
        ct0.redeem(ct0.maxRedeem(Alice), Alice, Alice);
        ct1.redeem(ct1.maxRedeem(Alice), Alice, Alice);
        uint256 deposit1 = uint256(positionSizeSeed);
        uint256 deposit0 = ((((uint256(positionSizeSeed) * 2 ** 96) / currentSqrtPriceX96) *
            2 ** 96) / currentSqrtPriceX96);
        console2.log("deposit0, deposit1", deposit0, deposit1);
        ct0.deposit(deposit0, Alice);
        ct1.deposit(deposit1, Alice);
        /// position size is denominated in the opposite of asset, so we do it in the token that is not WETH
        // leg 1
        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (currentTick / tickSpacing) * tickSpacing - 6 * tickSpacing,
                2
            )
            .addLeg(
                1,
                1,
                1,
                0,
                1,
                1,
                (currentTick / tickSpacing) * tickSpacing + 6 * tickSpacing,
                2
            );
        TokenId[] memory posIdList = new TokenId[](1);
        {
            posIdList[0] = tokenId;
            console2.log("mint 1");

            mintOptions(
                pp,
                posIdList,
                uint128((positionSizeSeed * 350) / 100),
                0,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
            console2.log(
                "bal0, bal1",
                ct0.convertToAssets(ct0.balanceOf(Alice)),
                ct1.convertToAssets(ct1.balanceOf(Alice))
            );
        }

        {
            console2.log("pp.numberOfLegs", pp.numberOfLegs(Alice));

            console2.log(
                "bal0, bal1",
                ct0.convertToAssets(ct0.balanceOf(Alice)),
                ct1.convertToAssets(ct1.balanceOf(Alice))
            );
            int24 liquidationPriceUp;
            int24 liquidationPriceDown;
            (liquidationPriceDown, liquidationPriceUp) = pq.getLiquidationPrices(
                pp,
                Alice,
                posIdList
            );

            console2.log(
                "collateralBalance, requiredCollateral",
                collateralBalance,
                requiredCollateral
            );
            // make sure it's liquidatable
            assertTrue(liquidationPriceUp < int24(2 ** 22), "not liquidatable up");
            assertTrue(liquidationPriceDown > -int24(2 ** 22), "not liquidatable down");

            // check that the account is liquidatble
            bool solvent = pq.isAccountSolvent(pp, Alice, posIdList, liquidationPriceDown + 1);
            assertTrue(solvent, "not liquidatable");

            solvent = pq.isAccountSolvent(pp, Alice, posIdList, liquidationPriceDown - 1);
            assertTrue(!solvent, "liquidatable");

            solvent = pq.isAccountSolvent(pp, Alice, posIdList, liquidationPriceUp - 1);
            assertTrue(solvent, "not liquidatable");

            solvent = pq.isAccountSolvent(pp, Alice, posIdList, liquidationPriceUp + 1);
            assertTrue(!solvent, "liquidatable");

            (uint256[4][] memory data, int256[] memory ticks, ) = pq.checkCollateralListOutput(
                pp,
                Alice,
                posIdList
            );
        }
    }

    function test_ScanChunks_and_GetChunkData_UsesPoolAsAccount(uint256 x) public {
        _initPool(x);

        // --- fund Alice similarly to your sample ---
        uint256 positionSizeSeed = 1e18;

        ct0.redeem(ct0.maxRedeem(Alice), Alice, Alice);
        ct1.redeem(ct1.maxRedeem(Alice), Alice, Alice);

        uint256 deposit1 = positionSizeSeed;
        uint256 deposit0 = ((((positionSizeSeed * 2 ** 96) / currentSqrtPriceX96) * 2 ** 96) /
            currentSqrtPriceX96);

        ct0.deposit(deposit0, Alice);
        ct1.deposit(deposit1, Alice);

        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (currentTick / tickSpacing) * tickSpacing - 6 * tickSpacing,
                2
            )
            .addLeg(
                1,
                1,
                1,
                0,
                1,
                1,
                (currentTick / tickSpacing) * tickSpacing + 6 * tickSpacing,
                2
            );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        mintOptions(
            pp,
            posIdList,
            uint128((positionSizeSeed * 350) / 100),
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // ============ 1) getChunkData correctness ============
        // It should now read SFPM.getAccountLiquidity(poolKey, address(pp), ...)
        uint256[2][4][] memory chunkData = pq.getChunkData(pp, posIdList);

        // check each leg matches raw SFPM reads for account=address(pp)
        bytes memory poolKey = pp.poolKey();
        address poolAsAccount = address(pp);

        for (uint256 j; j < tokenId.countLegs(); ++j) {
            (int24 tl, int24 tu) = tokenId.asTicks(j);
            uint8 tokenType = uint8(tokenId.tokenType(j));

            LeftRightUnsigned liq = sfpm.getAccountLiquidity(
                poolKey,
                poolAsAccount,
                tokenType,
                tl,
                tu
            );

            // net liquidity
            assertEq(chunkData[0][j][0], liq.rightSlot(), "net mismatch");
            // removed liquidity
            assertEq(chunkData[0][j][1], liq.leftSlot(), "removed mismatch");
        }

        // ============ 2) scanChunks discovers those chunks ============
        // We scan a range that definitely covers both legs, using the per-leg width.
        (int24 tl0, int24 tu0) = tokenId.asTicks(0);
        (int24 tl1, int24 tu1) = tokenId.asTicks(1);

        int24 width0 = tu0 - tl0;
        int24 width1 = tu1 - tl1;
        // In your constructions width should be identical for both legs; enforce to avoid silent mismatches.
        assertEq(width0, width1, "legs have different widths");

        int24[] memory strikes;
        uint128[2][] memory net;
        uint128[2][] memory removed;

        {
            int24 width = width0;

            int24 lower = _min24(tl0, tl1) - 2 * tickSpacing;
            int24 upper = _max24(tu0, tu1) + 2 * tickSpacing;

            (strikes, net, removed, ) = pq.scanChunks(pp, lower, upper, width);
        }
        // We expect to see exactly two non-empty chunks (one at each leg's tick range).
        // If your protocol can accumulate extra liquidity at adjacent ranges in this setup, loosen this to ">=2"
        // and then check membership instead of length.
        assertEq(strikes.length, 2, "unexpected number of discovered chunks");
        assertEq(net.length, 2, "net len");
        assertEq(removed.length, 2, "removed len");

        uint256 idxA;
        uint256 idxB;

        {
            int24 strikeA = (tu0 + tl0) / 2;
            int24 strikeB = (tu1 + tl1) / 2;

            // find indices in returned arrays
            idxA = _findStrike(strikes, strikeA);
            idxB = _findStrike(strikes, strikeB);
        }
        assertTrue(idxA != type(uint256).max, "strikeA not found");
        assertTrue(idxB != type(uint256).max, "strikeB not found");
        assertTrue(idxA != idxB, "same index for both strikes");
        // verify returned liquidity matches SFPM for BOTH token types at that (tl,tu)
        _assertScanEntryMatchesSFPM(poolKey, poolAsAccount, tl0, tu0, idxA, net, removed);
        _assertScanEntryMatchesSFPM(poolKey, poolAsAccount, tl1, tu1, idxB, net, removed);
    }

    function test_ScanChunks_FindsRemovedLiquidity_ForLongStraddle(uint256 x) public {
        _initPool(x);

        uint256 positionSizeSeed = 1e18;

        vm.startPrank(Bob);
        ct0.redeem(ct0.maxRedeem(Bob), Bob, Bob);
        ct1.redeem(ct1.maxRedeem(Bob), Bob, Bob);

        uint256 deposit1 = positionSizeSeed;
        uint256 deposit0 = ((((positionSizeSeed * 2 ** 96) / currentSqrtPriceX96) * 2 ** 96) /
            currentSqrtPriceX96);

        ct0.deposit(deposit0, Bob);
        ct1.deposit(deposit1, Bob);

        TokenId tokenId = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (currentTick / tickSpacing) * tickSpacing - 6 * tickSpacing,
                2
            )
            .addLeg(
                1,
                1,
                1,
                0,
                1,
                1,
                (currentTick / tickSpacing) * tickSpacing + 6 * tickSpacing,
                2
            );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        mintOptions(
            pp,
            posIdList,
            uint128((positionSizeSeed * 350) / 100),
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Alice);

        ct0.redeem(ct0.maxRedeem(Alice), Alice, Alice);
        ct1.redeem(ct1.maxRedeem(Alice), Alice, Alice);

        deposit1 = positionSizeSeed;
        deposit0 = ((((positionSizeSeed * 2 ** 96) / currentSqrtPriceX96) * 2 ** 96) /
            currentSqrtPriceX96);

        ct0.deposit(deposit0, Alice);
        ct1.deposit(deposit1, Alice);

        // long straddle (removed-liquidity legs)
        TokenId longStraddleTokenId = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(
                0,
                1,
                1,
                1, // remove liquidity
                0,
                0,
                (currentTick / tickSpacing) * tickSpacing - 6 * tickSpacing,
                2
            )
            .addLeg(
                1,
                1,
                1,
                1, // remove liquidity
                1,
                1,
                (currentTick / tickSpacing) * tickSpacing + 6 * tickSpacing,
                2
            );

        TokenId[] memory posIdList2 = new TokenId[](1);
        posIdList2[0] = longStraddleTokenId;

        mintOptions(
            pp,
            posIdList2,
            uint128((positionSizeSeed * 250) / 100),
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        bytes memory poolKey = pp.poolKey();
        address poolAsAccount = address(pp);

        (int24 tl0, int24 tu0) = longStraddleTokenId.asTicks(0);
        (int24 tl1, int24 tu1) = longStraddleTokenId.asTicks(1);

        int24[] memory strikes;
        uint128[2][] memory net;
        uint128[2][] memory removed;
        {
            int24 width = tu0 - tl0;
            assertEq(width, tu1 - tl1, "legs have different widths");

            int24 lower = _min24(tl0, tl1) - 2 * tickSpacing;
            int24 upper = _max24(tu0, tu1) + 2 * tickSpacing;

            (strikes, net, removed, ) = pq.scanChunks(pp, lower, upper, width);
        }

        // Must at least discover the two leg ranges.
        assertTrue(strikes.length >= 2, "did not discover enough chunks");

        uint256 idxA;
        uint256 idxB;
        {
            int24 strikeA = (tu0 + tl0) / 2;
            int24 strikeB = (tu1 + tl1) / 2;

            idxA = _findStrike(strikes, strikeA);
            idxB = _findStrike(strikes, strikeB);
        }
        assertTrue(idxA != type(uint256).max, "strikeA not found");
        assertTrue(idxB != type(uint256).max, "strikeB not found");

        _assertScanEntryMatchesSFPM(poolKey, poolAsAccount, tl0, tu0, idxA, net, removed);
        _assertScanEntryMatchesSFPM(poolKey, poolAsAccount, tl1, tu1, idxB, net, removed);

        // For removed-liquidity positions, we expect at least one of the removed slots to be nonzero
        // at each discovered leg range.
        assertTrue(
            (removed[idxA][0] | removed[idxA][1]) != 0,
            "expected removed liquidity at strikeA"
        );
        assertTrue(
            (removed[idxB][0] | removed[idxB][1]) != 0,
            "expected removed liquidity at strikeB"
        );
    }

    /// forge-config: default.fuzz.runs = 100
    function test_Success_optimizePartners(
        uint256 x,
        uint256 seed,
        int256 strikeSeed,
        uint256 widthSeed
    ) public {
        _initPool(x);

        seed = uint256(keccak256(abi.encode(seed)));
        console2.log("seed", seed);
        uint256 numberOfLegs = ((seed >> 222) % 4) + 1;

        TokenIdHelper.Leg[] memory inputLeg = new TokenIdHelper.Leg[](numberOfLegs);

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId);

        for (uint256 leg; leg < numberOfLegs; ++leg) {
            tokenId = tokenId.addRiskPartner(leg, leg);
        }

        // keep option ratio same for all
        uint256 optionRatio = uint256(seed % 2 ** 7);
        optionRatio = optionRatio == 0 ? 1 : optionRatio;

        // keep asset same for all
        uint256 asset = uint256((seed >> 9) % 2);

        for (uint256 i; i < numberOfLegs; ++i) {
            // update seed
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 isLong;
            {
                isLong = uint256((seed >> 7) % 2);

                uint256 tokenType = uint256((seed >> 27) % 2);
                tokenId = tokenId.addTokenType(tokenType, i);
                // add optionRatio
                tokenId = tokenId.addOptionRatio(optionRatio, i);

                // add isLong
                tokenId = tokenId.addIsLong(isLong, i);

                // add asset
                tokenId = tokenId.addAsset(asset, i);
            }
            // add strike
            int24 strike = (int24(bound(strikeSeed, -500_000, 500_000)) / pool.tickSpacing()) *
                pool.tickSpacing();
            tokenId = tokenId.addStrike(strike, i);

            // add width
            int24 width = int24(uint24(2 * bound(widthSeed, 1, 100)));

            tokenId = tokenId.addWidth(width, i);

            // add to input array of legs
            TokenIdHelper.Leg memory _Leg = TokenIdHelper.Leg({
                poolId: poolId,
                optionRatio: optionRatio,
                asset: asset,
                isLong: isLong,
                tokenType: tokenId.tokenType(i),
                riskPartner: tokenId.riskPartner(i),
                strike: strike,
                width: width
            });
            inputLeg[i] = _Leg;
        }

        uint256 requiredBefore = pq.getRequiredBase(pp, tokenId, currentTick);
        TokenId optimizedTokenId = pq.optimizeRiskPartners(pp, currentTick, tokenId);
        uint256 requiredAfter = pq.getRequiredBase(pp, optimizedTokenId, currentTick);
        console2.log("tokenIds", TokenId.unwrap(tokenId), TokenId.unwrap(optimizedTokenId));
        assertTrue(requiredAfter <= requiredBefore);
        console2.log("requiredAfter, requiredBefore", requiredAfter, requiredBefore);
        if (requiredAfter < requiredBefore) {
            for (uint256 leg; leg != numberOfLegs; leg++) {
                console2.log(
                    "leg, partner BEFORE,AFTER",
                    leg,
                    tokenId.riskPartner(leg),
                    optimizedTokenId.riskPartner(leg)
                );
            }
        }
    }
}
