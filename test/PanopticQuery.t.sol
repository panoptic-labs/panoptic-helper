// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// import "forge-std/Test.sol";
// import {Errors} from "@libraries/Errors.sol";
// import {PanopticMath} from "@libraries/PanopticMath.sol";
// import {Math} from "@libraries/Math.sol";
// import {Constants} from "@libraries/Constants.sol";
// import {TokenId} from "@types/TokenId.sol";
// import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
// import {LiquidityChunk} from "@types/LiquidityChunk.sol";
// import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
// import {TickMath} from "v3-core/libraries/TickMath.sol";
// import {FullMath} from "v3-core/libraries/FullMath.sol";
// import {FixedPoint128} from "v3-core/libraries/FixedPoint128.sol";
// import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
// import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
// import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
// import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
// import {PositionKey} from "v3-periphery/libraries/PositionKey.sol";
// import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
// import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// import {PanopticPool} from "@contracts/PanopticPool.sol";
// import {CollateralTracker} from "@contracts/CollateralTracker.sol";
// import {PanopticFactory} from "@contracts/PanopticFactory.sol";
// import {PanopticQuery} from "../src/PanopticQuery.sol";
// import {TokenIdHelper} from "../src/TokenIdHelper.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {PositionUtils} from "lib/panoptic-v1-core/test/foundry/testUtils/PositionUtils.sol";
// import {UniPoolPriceMock} from "lib/panoptic-v1-core/test/foundry/testUtils/PriceMocks.sol";
// import {Pointer} from "@types/Pointer.sol";

// contract SemiFungiblePositionManagerHarness is SemiFungiblePositionManager {
//     constructor(IUniswapV3Factory _factory) SemiFungiblePositionManager(_factory, 10 ** 13, 0) {}

//     function addrToPoolId(address pool) public view returns (uint256) {
//         return s_AddrToPoolIdData[pool];
//     }
// }

// contract PanopticPoolHarness is PanopticPool {
//     /// @notice get the positions hash of an account
//     /// @param user the account to get the positions hash of
//     /// @return _positionsHash positions hash of the account
//     function positionsHash(address user) external view returns (uint248 _positionsHash) {
//         _positionsHash = uint248(s_positionsHash[user]);
//     }

//     /**
//      * @notice compute the TWAP price from the last 600s = 10mins
//      * @return twapTick the TWAP price in ticks
//      */
//     function getUniV3TWAP_() external view returns (int24 twapTick) {
//         twapTick = PanopticMath.twapFilter(s_univ3pool, TWAP_WINDOW);
//     }

//     constructor(SemiFungiblePositionManager _sfpm) PanopticPool(_sfpm) {}
// }

// contract PanopticQueryTest is PositionUtils {
//     /*//////////////////////////////////////////////////////////////
//                            MAINNET CONTRACTS
//     //////////////////////////////////////////////////////////////*/

//     // the instance of SFPM we are testing
//     SemiFungiblePositionManagerHarness sfpm;

//     // A TokenIdHelper for getting equivalent token IDs as need be
//     TokenIdHelper tih;

//     // reference implemenatations used by the factory
//     address poolReference;

//     address collateralReference;

//     // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
//     IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

//     // Mainnet router address - used for swaps to test fees/premia
//     ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

//     address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

//     // used as example of price parity
//     IUniswapV3Pool constant USDC_USDT_5 =
//         IUniswapV3Pool(0x7858E59e0C01EA06Df3aF3D20aC7B0003275D4Bf);

//     // store a few different mainnet pairs - the pool used is part of the fuzz
//     IUniswapV3Pool constant USDC_WETH_5 =
//         IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
//     IUniswapV3Pool constant WBTC_ETH_30 =
//         IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
//     IUniswapV3Pool constant USDC_WETH_30 =
//         IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
//     IUniswapV3Pool[3] public pools = [USDC_WETH_5, WBTC_ETH_30, USDC_WETH_30];

//     /*//////////////////////////////////////////////////////////////
//                               WORLD STATE
//     //////////////////////////////////////////////////////////////*/

//     // store some data about the pool we are testing
//     IUniswapV3Pool pool;
//     uint64 poolId;
//     address token0;
//     address token1;
//     // We range position size in terms of WETH, so need to figure out which token is WETH
//     uint256 isWETH;
//     uint24 fee;
//     int24 tickSpacing;
//     uint160 currentSqrtPriceX96;
//     int24 currentTick;
//     uint256 feeGrowthGlobal0X128;
//     uint256 feeGrowthGlobal1X128;
//     uint256 poolBalance0;
//     uint256 poolBalance1;

//     int24 medianTick;
//     int24 TWAPtick;

//     PanopticFactory factory;
//     PanopticPoolHarness pp;
//     PanopticQuery pq;
//     CollateralTracker ct0;
//     CollateralTracker ct1;

//     address Deployer = address(0x1234);
//     address Alice = address(0x123456);
//     address Bob = address(0x12345678);
//     address Swapper = address(0x123456789);
//     address Charlie = address(0x1234567891);
//     address Seller = address(0x12345678912);

//     /*//////////////////////////////////////////////////////////////
//                                TEST DATA
//     //////////////////////////////////////////////////////////////*/

//     // used to pass into libraries
//     mapping(TokenId tokenId => uint256 balance) userBalance;

//     mapping(address actor => uint256 lastBalance0) lastCollateralBalance0;
//     mapping(address actor => uint256 lastBalance1) lastCollateralBalance1;

//     int24 tickLower;
//     int24 tickUpper;
//     uint160 sqrtLower;
//     uint160 sqrtUpper;

//     uint128 positionSize;
//     uint128 positionSizeBurn;

//     uint128 expectedLiq;
//     uint128 expectedLiqMint;
//     uint128 expectedLiqBurn;

//     int256 $amount0Moved;
//     int256 $amount1Moved;
//     int256 $amount0MovedMint;
//     int256 $amount1MovedMint;
//     int256 $amount0MovedBurn;
//     int256 $amount1MovedBurn;

//     int128 $expectedPremia0;
//     int128 $expectedPremia1;

//     int24[] tickLowers;
//     int24[] tickUppers;
//     uint160[] sqrtLowers;
//     uint160[] sqrtUppers;

//     uint128[] positionSizes;
//     uint128[] positionSizesBurn;

//     uint128[] expectedLiqs;
//     uint128[] expectedLiqsMint;
//     uint128[] expectedLiqsBurn;

//     int24 $width;
//     int24 $strike;
//     int24 $width2;
//     int24 $strike2;

//     uint256[] tokenIds;

//     int256[] $amount0Moveds;
//     int256[] $amount1Moveds;
//     int256[] $amount0MovedsMint;
//     int256[] $amount1MovedsMint;
//     int256[] $amount0MovedsBurn;
//     int256[] $amount1MovedsBurn;

//     int128[] $expectedPremias0;
//     int128[] $expectedPremias1;

//     int256 $swap0;
//     int256 $swap1;
//     int256 $itm0;
//     int256 $itm1;
//     int256 $intrinsicValue0;
//     int256 $intrinsicValue1;
//     int256 $ITMSpread0;
//     int256 $ITMSpread1;

//     int256 $balanceDelta0;
//     int256 $balanceDelta1;

//     LeftRightUnsigned tokenData0;
//     LeftRightUnsigned tokenData1;

//     uint256 collateralBalance;
//     uint256 requiredCollateral;

//     uint256 calculatedCollateralBalance;
//     uint256 calculatedRequiredCollateral;

//     int24 atTick;

//     TokenId positionSolo;

//     /*//////////////////////////////////////////////////////////////
//                                ENV SETUP
//     //////////////////////////////////////////////////////////////*/

//     function _initPool(uint256 seed) internal {
//         _initWorld(seed);
//     }

//     function _initWorldAtTick(uint256 seed, int24 tick) internal {
//         // Pick a pool from the seed and cache initial state
//         _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

//         // replace pool with a mock and set the tick
//         vm.etch(address(pool), address(new UniPoolPriceMock()).code);

//         UniPoolPriceMock(address(pool)).construct(
//             UniPoolPriceMock.Slot0(TickMath.getSqrtRatioAtTick(tick), tick, 0, 0, 0, 0, true),
//             address(token0),
//             address(token1),
//             fee,
//             tickSpacing
//         );

//         _deployPanopticPool();

//         _initAccounts();
//     }

//     function _initWorld(uint256 seed) internal {
//         // Pick a pool from the seed and cache initial state
//         _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

//         _deployPanopticPool();

//         _initAccounts();
//     }

//     function _cacheWorldState(IUniswapV3Pool _pool) internal {
//         pool = _pool;
//         poolId = PanopticMath.getPoolId(address(_pool), _pool.tickSpacing());
//         token0 = _pool.token0();
//         token1 = _pool.token1();
//         isWETH = token0 == address(WETH) ? 0 : 1;
//         fee = _pool.fee();
//         tickSpacing = _pool.tickSpacing();
//         (currentSqrtPriceX96, currentTick, , , , , ) = _pool.slot0();
//         feeGrowthGlobal0X128 = _pool.feeGrowthGlobal0X128();
//         feeGrowthGlobal1X128 = _pool.feeGrowthGlobal1X128();
//         poolBalance0 = IERC20Partial(token0).balanceOf(address(_pool));
//         poolBalance1 = IERC20Partial(token1).balanceOf(address(_pool));
//     }

//     function _deployPanopticPool() internal {
//         vm.startPrank(Deployer);

//         factory = new PanopticFactory(
//             sfpm,
//             V3FACTORY,
//             poolReference,
//             collateralReference,
//             new bytes32[](0),
//             new uint256[][](0),
//             new Pointer[][](0)
//         );

//         deal(token0, Deployer, type(uint104).max);
//         deal(token1, Deployer, type(uint104).max);
//         IERC20Partial(token0).approve(address(factory), type(uint104).max);
//         IERC20Partial(token1).approve(address(factory), type(uint104).max);

//         pp = PanopticPoolHarness(
//             address(factory.deployNewPool(token0, token1, fee, uint96(block.timestamp)))
//         );

//         ct0 = pp.collateralToken0();
//         ct1 = pp.collateralToken1();
//     }

//     function _initAccounts() internal {
//         vm.startPrank(Swapper);

//         IERC20Partial(token0).approve(address(router), type(uint256).max);
//         IERC20Partial(token1).approve(address(router), type(uint256).max);

//         deal(token0, Swapper, type(uint104).max);
//         deal(token1, Swapper, type(uint104).max);

//         vm.startPrank(Charlie);

//         deal(token0, Charlie, type(uint104).max);
//         deal(token1, Charlie, type(uint104).max);

//         IERC20Partial(token0).approve(address(router), type(uint256).max);
//         IERC20Partial(token1).approve(address(router), type(uint256).max);
//         IERC20Partial(token0).approve(address(pp), type(uint256).max);
//         IERC20Partial(token1).approve(address(pp), type(uint256).max);
//         IERC20Partial(token0).approve(address(ct0), type(uint256).max);
//         IERC20Partial(token1).approve(address(ct1), type(uint256).max);

//         vm.startPrank(Seller);

//         deal(token0, Seller, type(uint104).max);
//         deal(token1, Seller, type(uint104).max);

//         IERC20Partial(token0).approve(address(router), type(uint256).max);
//         IERC20Partial(token1).approve(address(router), type(uint256).max);
//         IERC20Partial(token0).approve(address(pp), type(uint256).max);
//         IERC20Partial(token1).approve(address(pp), type(uint256).max);
//         IERC20Partial(token0).approve(address(ct0), type(uint256).max);
//         IERC20Partial(token1).approve(address(ct1), type(uint256).max);

//         ct0.deposit(type(uint104).max, Seller);
//         ct1.deposit(type(uint104).max, Seller);

//         // cancel out MEV tax and push exchange rate back to 1
//         deal(address(ct0), Seller, type(uint104).max, true);
//         deal(address(ct1), Seller, type(uint104).max, true);

//         vm.startPrank(Bob);
//         // account for MEV tax
//         deal(token0, Bob, (type(uint104).max * uint256(1010)) / 1000);
//         deal(token1, Bob, (type(uint104).max * uint256(1010)) / 1000);

//         IERC20Partial(token0).approve(address(router), type(uint256).max);
//         IERC20Partial(token1).approve(address(router), type(uint256).max);
//         IERC20Partial(token0).approve(address(pp), type(uint256).max);
//         IERC20Partial(token1).approve(address(pp), type(uint256).max);
//         IERC20Partial(token0).approve(address(ct0), type(uint256).max);
//         IERC20Partial(token1).approve(address(ct1), type(uint256).max);

//         ct0.deposit(type(uint104).max, Bob);
//         ct1.deposit(type(uint104).max, Bob);

//         // cancel out MEV tax and push exchange rate back to 1
//         deal(address(ct0), Bob, type(uint104).max, true);
//         deal(address(ct1), Bob, type(uint104).max, true);

//         vm.startPrank(Alice);

//         deal(token0, Alice, type(uint104).max);
//         deal(token1, Alice, type(uint104).max);

//         IERC20Partial(token0).approve(address(router), type(uint256).max);
//         IERC20Partial(token1).approve(address(router), type(uint256).max);
//         IERC20Partial(token0).approve(address(pp), type(uint256).max);
//         IERC20Partial(token1).approve(address(pp), type(uint256).max);
//         IERC20Partial(token0).approve(address(ct0), type(uint256).max);
//         IERC20Partial(token1).approve(address(ct1), type(uint256).max);

//         ct0.deposit(type(uint104).max, Alice);
//         ct1.deposit(type(uint104).max, Alice);

//         // cancel out MEV tax and push exchange rate back to 1
//         deal(address(ct0), Alice, type(uint104).max, true);
//         deal(address(ct1), Alice, type(uint104).max, true);
//     }

//     function setUp() public {
//         sfpm = new SemiFungiblePositionManagerHarness(V3FACTORY);
//         pq = new PanopticQuery(SemiFungiblePositionManager(sfpm));
//         tih = new TokenIdHelper(SemiFungiblePositionManager(sfpm));

//         // deploy reference pool and collateral token
//         poolReference = address(new PanopticPoolHarness(sfpm));
//         collateralReference = address(
//             new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
//         );
//     }

//     /*//////////////////////////////////////////////////////////////
//                           TEST DATA POPULATION
//     //////////////////////////////////////////////////////////////*/

//     function populatePositionData(
//         int24[2] memory width,
//         int24[2] memory strike,
//         uint256[2] memory positionSizeSeeds
//     ) internal {
//         tickLowers.push(int24(strike[0] - (width[0] * tickSpacing) / 2));
//         tickUppers.push(int24(strike[0] + (width[0] * tickSpacing) / 2));
//         sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[0]));
//         sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[0]));

//         tickLowers.push(int24(strike[1] - (width[1] * tickSpacing) / 2));
//         tickUppers.push(int24(strike[1] + (width[1] * tickSpacing) / 2));
//         sqrtLowers.push(TickMath.getSqrtRatioAtTick(tickLowers[1]));
//         sqrtUppers.push(TickMath.getSqrtRatioAtTick(tickUppers[1]));

//         // 0.0001 -> 10_000 WETH
//         positionSizeSeeds[0] = bound(positionSizeSeeds[0], 10 ** 15, 10 ** 22);
//         positionSizeSeeds[1] = bound(positionSizeSeeds[1], 10 ** 15, 10 ** 22);

//         // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
//         positionSizes.push(
//             uint128(
//                 getContractsForAmountAtTick(
//                     currentTick,
//                     tickLowers[0],
//                     tickUppers[0],
//                     isWETH,
//                     positionSizeSeeds[0]
//                 )
//             )
//         );

//         positionSizes.push(
//             uint128(
//                 getContractsForAmountAtTick(
//                     currentTick,
//                     tickLowers[1],
//                     tickUppers[1],
//                     isWETH,
//                     positionSizeSeeds[1]
//                 )
//             )
//         );

//         // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
//         // as well and using the original value could result in discrepancies due to rounding
//         expectedLiqs.push(
//             isWETH == 0
//                 ? LiquidityAmounts.getLiquidityForAmount0(
//                     sqrtLowers[0],
//                     sqrtUppers[0],
//                     positionSizes[0]
//                 )
//                 : LiquidityAmounts.getLiquidityForAmount1(
//                     sqrtLowers[0],
//                     sqrtUppers[0],
//                     positionSizes[0]
//                 )
//         );

//         expectedLiqs.push(
//             isWETH == 0
//                 ? LiquidityAmounts.getLiquidityForAmount0(
//                     sqrtLowers[1],
//                     sqrtUppers[1],
//                     positionSizes[1]
//                 )
//                 : LiquidityAmounts.getLiquidityForAmount1(
//                     sqrtLowers[1],
//                     sqrtUppers[1],
//                     positionSizes[1]
//                 )
//         );
//     }

//     // returns token containing 'totalLegs' amount of legs
//     // i.e totalLegs of 1 has a tokenId with 1 legs
//     // uses a seed to fuzz data so that there is different data for each leg
//     function fuzzedPosition(
//         uint256 totalLegs,
//         uint256 optionRatioSeed,
//         uint256 assetSeed,
//         uint256 isLongSeed,
//         uint256 tokenTypeSeed,
//         int256 strikeSeed,
//         int256 widthSeed
//     ) internal returns (TokenId) {
//         TokenId tokenId = TokenId.wrap(uint256(poolId));

//         for (uint256 legIndex; legIndex < totalLegs; legIndex++) {
//             // We don't want the same data for each leg
//             // int divide each seed by the current legIndex
//             // gives us a pseudorandom seed
//             // forge bound does not randomize the output
//             {
//                 uint256 randomizer = legIndex + 1;

//                 optionRatioSeed = optionRatioSeed / randomizer;
//                 assetSeed = assetSeed / randomizer;
//                 isLongSeed = isLongSeed / randomizer;
//                 tokenTypeSeed = tokenTypeSeed / randomizer;
//                 strikeSeed = strikeSeed / int24(int256(randomizer));
//                 widthSeed = widthSeed / int24(int256(randomizer));
//             }

//             {
//                 // the following are all 1 bit so mask them:
//                 uint16 MASK = 0x1; // takes first 1 bit of the uint16
//                 assetSeed = assetSeed & MASK;
//                 isLongSeed = isLongSeed & MASK;
//                 tokenTypeSeed = tokenTypeSeed & MASK;
//             }

//             /// bound inputs
//             int24 strike;
//             int24 width;
//             {
//                 // the following must be at least 1
//                 optionRatioSeed = bound(optionRatioSeed, 1, 127);

//                 width = int24(bound(widthSeed, 1, 4094));
//                 int24 oneSidedRange = (width * tickSpacing) / 2;

//                 (int24 strikeOffset, int24 minTick, int24 maxTick) = PositionUtils.getContextFull(
//                     uint256(uint24(tickSpacing)),
//                     currentTick,
//                     width
//                 );

//                 int24 lowerBound = int24(minTick + oneSidedRange - strikeOffset);
//                 int24 upperBound = int24(maxTick - oneSidedRange - strikeOffset);

//                 // Set current tick and pool price
//                 currentTick = int24(bound(currentTick, minTick, maxTick));
//                 currentSqrtPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);

//                 // bound strike
//                 strike = int24(
//                     bound(strikeSeed, lowerBound / tickSpacing, upperBound / tickSpacing)
//                 );
//                 strike = int24(strike * tickSpacing + strikeOffset);
//             }

//             {
//                 // add a leg
//                 // no risk partner by default (will reference its own leg index)
//                 tokenId = tokenId.addLeg(
//                     legIndex,
//                     optionRatioSeed,
//                     assetSeed,
//                     isLongSeed,
//                     tokenTypeSeed,
//                     legIndex,
//                     strike,
//                     width
//                 );
//             }
//         }

//         return tokenId;
//     }

//     function test_Success_checkCollateral_OTMandITMShortCall(
//         uint256 x,
//         uint256[2] memory widthSeeds,
//         int256[2] memory strikeSeeds,
//         uint256[2] memory positionSizeSeeds,
//         int256 atTickSeed
//     ) public {
//         _initPool(x);

//         ($width, $strike) = PositionUtils.getOTMSW(
//             widthSeeds[0],
//             strikeSeeds[0],
//             uint24(tickSpacing),
//             currentTick,
//             0
//         );

//         ($width2, $strike2) = PositionUtils.getITMSW(
//             widthSeeds[1],
//             strikeSeeds[1],
//             uint24(tickSpacing),
//             currentTick,
//             1
//         );
//         vm.assume($width2 != $width || $strike2 != $strike);

//         populatePositionData([$width, $width2], [$strike, $strike2], positionSizeSeeds);

//         atTick = int24(bound(atTickSeed, TickMath.MIN_TICK, TickMath.MAX_TICK));

//         /// position size is denominated in the opposite of asset, so we do it in the token that is not WETH
//         // leg 1
//         TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             0,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         // leg 2
//         TokenId tokenId2 = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             0,
//             1,
//             0,
//             $strike2,
//             $width2
//         );
//         {
//             TokenId[] memory posIdList = new TokenId[](1);
//             posIdList[0] = tokenId;

//             pp.mintOptions(
//                 posIdList,
//                 positionSizes[0],
//                 0,
//                 Constants.MAX_V3POOL_TICK,
//                 Constants.MIN_V3POOL_TICK
//             );
//         }

//         {
//             TokenId[] memory posIdList = new TokenId[](2);
//             posIdList[0] = tokenId;
//             posIdList[1] = tokenId2;

//             pp.mintOptions(
//                 posIdList,
//                 positionSizes[1],
//                 0,
//                 Constants.MAX_V3POOL_TICK,
//                 Constants.MIN_V3POOL_TICK
//             );

//             (
//                 LeftRightUnsigned shortPremium,
//                 LeftRightUnsigned longPremium,
//                 uint256[2][] memory posBalanceArray
//             ) = pp.getAccumulatedFeesAndPositionsData(Alice, false, posIdList);

//             tokenData0 = ct0.getAccountMarginDetails(
//                 Alice,
//                 atTick,
//                 posBalanceArray,
//                 shortPremium.rightSlot(),
//                 longPremium.rightSlot()
//             );
//             tokenData1 = ct1.getAccountMarginDetails(
//                 Alice,
//                 atTick,
//                 posBalanceArray,
//                 shortPremium.leftSlot(),
//                 longPremium.leftSlot()
//             );

//             (calculatedCollateralBalance, calculatedRequiredCollateral) = PanopticMath
//                 .getCrossBalances(tokenData0, tokenData1, Math.getSqrtRatioAtTick(atTick));

//             // these are the balance/required cross, reusing variables to save stack space

//             if (atTick < 0)
//                 (collateralBalance, requiredCollateral, , ) = pq.checkCollateral(
//                     pp,
//                     Alice,
//                     atTick,
//                     posIdList
//                 );
//             else
//                 (, , collateralBalance, requiredCollateral) = pq.checkCollateral(
//                     pp,
//                     Alice,
//                     atTick,
//                     posIdList
//                 );

//             assertEq(collateralBalance, calculatedCollateralBalance);
//             assertEq(requiredCollateral, calculatedRequiredCollateral);

//             pq.checkCollateral(pp, Alice, posIdList);
//         }
//     }

//     function test_computeMinimumSize_returns_zero_if_no_purchase(
//         uint256 x,
//         uint256 widthSeed,
//         int256 strikeSeed
//     ) public {
//         _initPool(x);
//         ($width, $strike) = PositionUtils.getITMSW(
//             widthSeed,
//             strikeSeed,
//             uint24(tickSpacing),
//             currentTick,
//             0
//         );

//         // - alice mints a call to sell token0 at some size
//         TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             0,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         TokenId[] memory posIdList = new TokenId[](1);
//         posIdList[0] = tokenId;
//         // TODO: fuzz position size some day
//         pp.mintOptions(
//             posIdList,
//             10 ** 15,
//             0,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );
//         // - then immediately call computeMinimumSize
//         // it should return 0: no one has bought from you
//         uint128 minPositionSize = pq.computeMinimumSize(pp, Alice, tokenId);
//         assertEq(minPositionSize, 0);
//     }

//     function test_computeMinimumSize_returns_lower_size_if_small_purchase_made(
//         uint256 x,
//         uint256 widthSeed,
//         int256 strikeSeed
//     ) public {
//         _initPool(x);
//         ($width, $strike) = PositionUtils.getITMSW(
//             widthSeed,
//             strikeSeed,
//             uint24(tickSpacing),
//             currentTick,
//             0
//         );

//         // - alice mints a call to sell token0 at some size
//         TokenId callSaleTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             // Use an option ratio of 2 so that its easy to get an equivalentPosition later:
//             2,
//             isWETH,
//             0,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         TokenId[] memory posIdList = new TokenId[](1);
//         posIdList[0] = callSaleTokenId;
//         // TODO: fuzz position size some day
//         uint128 alicesSaleSize = 100 * 10 ** 15;
//         pp.mintOptions(
//             posIdList,
//             alicesSaleSize,
//             0,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );
//         // - bob mints a call purchase, to purchase < 90%
//         TokenId callPurchaseTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             // Use an option ratio of 2 so that its easy to get an equivalentPosition later:
//             2,
//             isWETH,
//             1,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         posIdList[0] = callPurchaseTokenId;
//         // TODO: fuzz the portion of alicesSaleSize some day; hardcoding half for now
//         uint128 bobsPurchaseSize = 50 * 10 ** 15;
//         vm.startPrank(Bob);
//         pp.mintOptions(
//             posIdList,
//             bobsPurchaseSize,
//             type(uint64).max,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );
//         // - then call computeMinimumSize on Alice
//         uint128 alicesMinPositionSize = pq.computeMinimumSize(pp, Alice, callSaleTokenId);
//         // With that value, we should be able to make some assertions about remint-and-burning:
//         // First - get a re-mintable tokenId by scaling down from the original option ratio of 2:
//         TokenId equivalentCallSaleTokenId = tih.scaledPosition(callSaleTokenId, 2, false);
//         alicesMinPositionSize *= 2;
//         TokenId[] memory remintingPosIdList = new TokenId[](2);
//         TokenId[] memory postburnPosIdList = new TokenId[](1);
//         remintingPosIdList[0] = callSaleTokenId;
//         remintingPosIdList[1] = equivalentCallSaleTokenId;
//         postburnPosIdList[0] = equivalentCallSaleTokenId;
//         bytes[] memory remintAndBurnMulticallData = new bytes[](2);
//         // In both subsequent tests, we plan to burn the original position:
//         remintAndBurnMulticallData[1] = abi.encodeWithSelector(
//             bytes4(keccak256("burnOptions(uint256,uint256[],int24,int24)")),
//             callSaleTokenId,
//             postburnPosIdList,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );
//         // (
//         //     int24 equivalentCallSaleTickLower,
//         //     int24 equivalentCallSaleTickUpper
//         // ) = equivalentCallSaleTokenId.asTicks(0);
//         vm.startPrank(Alice);
//         {
//             // 1. Alice should get a revert if she tries to remint-and-burn with 1 less than the min size
//             // TODO: computeMinimumSize is too conservative, so for now we're commenting out this test, and just checking
//             // that the position size was reduced at all:
//             assertLt(alicesMinPositionSize / 2, alicesSaleSize);
//             // But this is what it would look like to test that the reducedSize is truly as small as could be:
//             // remintAndBurnMulticallData[0] = abi.encodeWithSelector(
//             //     PanopticPool.mintOptions.selector,
//             //     remintingPosIdList,
//             //     /*
//             //     This is what the function should guarantee - this fails:
//             //     */
//             //     alicesMinPositionSize - 1,
//             //     */
//             //     /*
//             //     This is a lighter version that provides some tolerance -
//             //     e.g., it passes even if alicesMinPositionSize could have been up to 200k liq units smaller,
//             //     and passes with the current implementation (100k even usually passes):
//             //     */
//             //     alicesMinPositionSize -
//             //         (
//             //             LiquidityAmounts.getAmount1ForLiquidity(
//             //                 Math.getSqrtRatioAtTick(equivalentCallSaleTickLower),
//             //                 Math.getSqrtRatioAtTick(equivalentCallSaleTickUpper),
//             //                 200_000
//             //             )
//             //         ),
//             //     0,
//             //     Constants.MIN_V3POOL_TICK,
//             //     Constants.MAX_V3POOL_TICK
//             // );
//             // vm.expectRevert(Errors.EffectiveLiquidityAboveThreshold.selector);
//             // pp.multicall(remintAndBurnMulticallData);
//         }
//         {
//             // 2. Alice should be able to successfully remint-and-burn with exactly the min size:
//             remintAndBurnMulticallData[0] = abi.encodeWithSelector(
//                 PanopticPool.mintOptions.selector,
//                 remintingPosIdList,
//                 alicesMinPositionSize,
//                 0,
//                 Constants.MIN_V3POOL_TICK,
//                 Constants.MAX_V3POOL_TICK
//             );
//             pp.multicall(remintAndBurnMulticallData);
//             // 3. Bob should not be able to purchase even a fraction of what he did before after Alice successfully resizes down:
//             vm.startPrank(Bob);
//             // Scale down the tokenId the original option ratio of 2
//             // (and scale up purchase size to reflect the same size as before):
//             TokenId equivalentCallPurchaseTokenId = tih.scaledPosition(
//                 callPurchaseTokenId,
//                 2,
//                 false
//             );
//             bobsPurchaseSize *= 2;
//             TokenId[] memory bobsPostRepurchaseList = new TokenId[](2);
//             bobsPostRepurchaseList[0] = callPurchaseTokenId;
//             bobsPostRepurchaseList[1] = equivalentCallPurchaseTokenId;
//             vm.expectRevert(Errors.EffectiveLiquidityAboveThreshold.selector);
//             pp.mintOptions(
//                 bobsPostRepurchaseList,
//                 // Bob tries to buy one tenth as much as he did before
//                 bobsPurchaseSize / 10,
//                 type(uint64).max,
//                 Constants.MIN_V3POOL_TICK,
//                 Constants.MAX_V3POOL_TICK
//             );
//         }
//         // - finally, also call computeMinimumSize on Bob
//         // it should return type(uint128).max - bob has only long legs
//         uint128 bobsMinPositionSize = pq.computeMinimumSize(pp, Bob, callPurchaseTokenId);
//         assertEq(bobsMinPositionSize, 0);
//     }

//     function test_computeMinimumSize_returns_same_size_if_max_purchase_made(
//         uint256 x,
//         uint256 widthSeed,
//         int256 strikeSeed
//     ) public {
//         _initPool(x);
//         ($width, $strike) = PositionUtils.getITMSW(
//             widthSeed,
//             strikeSeed,
//             uint24(tickSpacing),
//             currentTick,
//             0
//         );

//         // - alice mints a call to sell token0 at some size
//         TokenId callSaleTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             0,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         TokenId[] memory posIdList = new TokenId[](1);
//         posIdList[0] = callSaleTokenId;
//         // TODO: fuzz position size some day
//         uint128 alicesSaleSize = 100 * 10 ** 15;
//         pp.mintOptions(
//             posIdList,
//             alicesSaleSize,
//             0,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );
//         // - bob mints a call purchase, to purchase exactly 90%
//         TokenId callPurchaseTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             1,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         posIdList[0] = callPurchaseTokenId;
//         uint128 bobsPurchaseSize = uint128(Math.mulDiv(uint256(alicesSaleSize), 9, 10));
//         vm.startPrank(Bob);
//         pp.mintOptions(
//             posIdList,
//             bobsPurchaseSize,
//             type(uint64).max,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );
//         // - then call computeMinimumSize on Alice
//         // it should return the original size alice minted, +/- some liquidity units
//         uint128 alicesMinPositionSize = pq.computeMinimumSize(pp, Alice, callSaleTokenId);
//         (int24 callSaleTickLower, int24 callSaleTickUpper) = callSaleTokenId.asTicks(0);
//         assertLt(
//             Math.absUint(int256(uint256(alicesMinPositionSize)) - int256(uint256(alicesSaleSize))),
//             LiquidityAmounts.getAmount1ForLiquidity(
//                 Math.getSqrtRatioAtTick(callSaleTickLower),
//                 Math.getSqrtRatioAtTick(callSaleTickUpper),
//                 2
//             ),
//             "alicesMinPositionSize was not within 2 liquidity units of alicesSaleSize after a 90% purchase"
//         );
//     }

//     function test_computeSoldPositionToSatisfyLongLegs_returns_zero_if_small_purchase_made(
//         uint256 x,
//         uint256 widthSeed,
//         int256 strikeSeed
//     ) public {
//         _initPool(x);
//         // alice sells 100 * 10 ** 15 calls
//         ($width, $strike) = PositionUtils.getITMSW(
//             widthSeed,
//             strikeSeed,
//             uint24(tickSpacing),
//             currentTick,
//             0
//         );

//         TokenId callSaleTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             0,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         TokenId[] memory posIdList = new TokenId[](1);
//         posIdList[0] = callSaleTokenId;
//         uint128 alicesSaleSize = 100 * 10 ** 15;
//         pp.mintOptions(
//             posIdList,
//             alicesSaleSize,
//             0,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );

//         // Bob purchases 10%
//         TokenId callPurchaseTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             1,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         posIdList[0] = callPurchaseTokenId;
//         uint128 bobsPurchaseSize = uint128(Math.mulDiv(uint256(alicesSaleSize), 1, 10));
//         vm.startPrank(Bob);
//         pp.mintOptions(
//             posIdList,
//             bobsPurchaseSize,
//             type(uint64).max,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );

//         // Bob tries to compute a sell-side position to satisfy another small purchase
//         (TokenId sellsidePosition, uint128 sellsidePositionSize) = pq
//             .computeSoldPositionToSatisfyLongLegs(pp, callPurchaseTokenId, bobsPurchaseSize);

//         // Assert no sell-side position is required
//         assertEq(
//             sellsidePosition.countLegs(),
//             0,
//             "There should be no legs on the returned sellside position, as the purchase easily fits within current liquidity"
//         );
//         assertEq(
//             sellsidePositionSize,
//             0,
//             "Sellside position size should be zero if no more liquidity necessary for purchase in question"
//         );
//     }

//     function test_computeSoldPositionToSatisfyLongLegs_returns_nonzero_if_max_purchase_made(
//         uint256 x,
//         uint256 widthSeed,
//         int256 strikeSeed
//     ) public {
//         _initPool(x);
//         ($width, $strike) = PositionUtils.getITMSW(
//             widthSeed,
//             strikeSeed,
//             uint24(tickSpacing),
//             currentTick,
//             0
//         );

//         // alice sells 100 * 10 ** 15 calls
//         TokenId callSaleTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             0,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         TokenId[] memory posIdList = new TokenId[](1);
//         posIdList[0] = callSaleTokenId;
//         uint128 alicesSaleSize = 100 * 10 ** 15;
//         pp.mintOptions(
//             posIdList,
//             alicesSaleSize,
//             0,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );

//         // Bob purchases 90%
//         TokenId callPurchaseTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
//             0,
//             1,
//             isWETH,
//             1,
//             0,
//             0,
//             $strike,
//             $width
//         );
//         posIdList[0] = callPurchaseTokenId;
//         uint128 bobsPurchaseSize = uint128(Math.mulDiv(uint256(alicesSaleSize), 9, 10));
//         vm.startPrank(Bob);
//         pp.mintOptions(
//             posIdList,
//             bobsPurchaseSize,
//             type(uint64).max,
//             Constants.MIN_V3POOL_TICK,
//             Constants.MAX_V3POOL_TICK
//         );

//         // Bob computes the sell-side position required to make another purchase in the same size
//         // (without more sales, he would drive util to 180%)
//         (TokenId sellsidePosition, uint128 sellsidePositionSize) = pq
//             .computeSoldPositionToSatisfyLongLegs(pp, callPurchaseTokenId, bobsPurchaseSize);

//         // Assert that a sell-side position is required and computed
//         assertTrue(
//             TokenId.unwrap(sellsidePosition) != 0,
//             "A sellside position should be returned because there is insufficient liquidity for another purchase of that size"
//         );
//         assertGt(
//             sellsidePositionSize,
//             0,
//             "Sellside position size should be non-zero if more liquidity is necessary for purchase in question"
//         );
//         // Assert that the returned sell-side position sells into the same chunk Bob wanted to buy into
//         uint256 sellAsset = sellsidePosition.asset(0);
//         uint256 sellTokenType = sellsidePosition.tokenType(0);
//         int24 sellStrike = sellsidePosition.strike(0);
//         int24 sellWidth = sellsidePosition.width(0);
//         assertEq(sellAsset, isWETH, "Sellside asset does not match expected");
//         assertEq(sellTokenType, 0, "Sellside token type should be type 0 like the minted position");
//         assertEq(sellStrike, $strike, "Sellside strike does not match expected");
//         assertEq(sellWidth, $width, "Sellside width does not match expected");
//     }

//     // TODO: test computeMinimumSize with multiple sellers, multiple buyers, multi-leg positions...
//     // TODO: fuzz more of the computeSoldPositionToSatisfyLongLegs test content, and also try the above multi scenarios
//     // TODO: mostly as an example, write a test where Alice has a position with both long and short legs,
//     // and show how you could first get a min size from computeMinimumSize, then call computeSoldPositionToSatisfyLongLegs
//     // to facilitate the full sequence of:
//     // 1. sell temporary sell-side position to satisfy long legs of new remintable position from computeMinimumSize
//     // 2. remint the returned position from computeMinimumSize
//     // 3. burn original position
//     // 4. burn temporary sell-side position from step (1)
//     // and can throw in all the scaledPosition / equivalentPosition calls you need too as good example

//     function test_getChunkData_returns_correct_liquidities() public {
//         // TODO:
//         // - PLP via the SFPM with token0,
//         // - mint a call-purchase at some fuzzed proportion of the sold volume
//         // - call getChunkData
//         // it should return a netLiquidity of originalSize - purchaseSize, and removedLiquidity of purchaseSize
//         // (both converted to liquidity units)
//     }
// }
