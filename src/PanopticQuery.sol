// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {LiquidityAmounts} from "univ3-periphery/libraries/LiquidityAmounts.sol";
import {FullMath} from "univ3-core/libraries/FullMath.sol";
import {FixedPoint96} from "univ3-core/libraries/FixedPoint96.sol";
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticQuery {
    /// @notice The SemiFungiblePositionManager of the Panoptic instance this querying helper is intended for.
    SemiFungiblePositionManager internal immutable SFPM;

    /// @notice Construct the PanopticQuery and store the SFPM address.
    /// @param SFPM_ The canonical SFPM address for the Panoptic instance this helper queries
    constructor(SemiFungiblePositionManager SFPM_) payable {
        SFPM = SFPM_;
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance0 The total combined balance of token0 and token1 for a user in terms of token0
    /// @return requiredCollateral0 The combined collateral requirement for a user in terms of token0
    /// @return collateralBalance1 The total combined balance of token0 and token1 for a user in terms of token1
    /// @return requiredCollateral1 The combined collateral requirement for a user in terms of token1
    function checkCollateral(
        PanopticPool pool,
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList
    )
        public
        view
        returns (
            uint256 collateralBalance0,
            uint256 requiredCollateral0,
            uint256 collateralBalance1,
            uint256 requiredCollateral1
        )
    {
        // Compute premia for all options (includes short+long premium)
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        // Query the current and required collateral amounts for the two tokens
        LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            shortPremium.rightSlot(),
            longPremium.rightSlot()
        );
        LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            shortPremium.leftSlot(),
            longPremium.leftSlot()
        );

        // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
        collateralBalance0 =
            tokenData0.rightSlot() +
            PanopticMath.convert1to0(tokenData1.rightSlot(), Math.getSqrtRatioAtTick(atTick));
        requiredCollateral0 =
            tokenData0.leftSlot() +
            PanopticMath.convert1to0RoundingUp(
                tokenData1.leftSlot(),
                Math.getSqrtRatioAtTick(atTick)
            );

        collateralBalance1 =
            tokenData1.rightSlot() +
            PanopticMath.convert0to1(tokenData0.rightSlot(), Math.getSqrtRatioAtTick(atTick));
        requiredCollateral1 =
            tokenData1.leftSlot() +
            PanopticMath.convert0to1RoundingUp(
                tokenData0.leftSlot(),
                Math.getSqrtRatioAtTick(atTick)
            );
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList at (currentTick, fastOracleTick, slowOracleTick, latestObservation).
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalances0 The total combined balance of token0 and token1 for a user in terms of token0 (currentTick, fastOracleTick, slowOracleTick, latestObservation)
    /// @return requiredCollaterals0 The combined collateral requirement for a user in terms of token0 (currentTick, fastOracleTick, slowOracleTick, latestObservation)
    /// @return collateralBalances1 The total combined balance of token0 and token1 for a user in terms of token1 (currentTick, fastOracleTick, slowOracleTick, latestObservation)
    /// @return requiredCollaterals1 The combined collateral requirement for a user in terms of token1 (currentTick, fastOracleTick, slowOracleTick, latestObservation)
    function checkCollateral(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    )
        public
        view
        returns (
            uint256[4] memory collateralBalances0,
            uint256[4] memory requiredCollaterals0,
            uint256[4] memory collateralBalances1,
            uint256[4] memory requiredCollaterals1
        )
    {
        int24[4] memory ticks;
        (ticks[0], ticks[1], ticks[2], ticks[3], ) = pool.getOracleTicks();
        for (uint256 i = 0; i < ticks.length; ++i) {
            (
                collateralBalances0[i],
                requiredCollaterals0[i],
                collateralBalances1[i],
                requiredCollaterals1[i]
            ) = checkCollateral(pool, account, ticks[i], positionIdList);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the median of the last `cardinality` average prices over `period` observations from `univ3pool`.
    /// @dev Used when we need a manipulation-resistant TWAP price.
    /// @dev Uniswap observations snapshot the closing price of the last block before the first interaction of a given block.
    /// @dev The maximum frequency of observations is 1 per block, but there is no guarantee that the pool will be observed at every block.
    /// @dev Each period has a minimum length of blocktime * period, but may be longer if the Uniswap pool is relatively inactive.
    /// @dev The final price used in the array (of length `cardinality`) is the average of all observations comprising `period` (which is itself a number of observations).
    /// @dev Thus, the minimum total time window is `cardinality` * `period` * `blocktime`.
    /// @param univ3pool The Uniswap pool to get the median observation from
    /// @param cardinality The number of `periods` to in the median price array, should be odd.
    /// @param period The number of observations to average to compute one entry in the median price array
    /// @return medianTick The median of `cardinality` observations spaced by `period` in the Uniswap pool
    function computeMedianObservedPrice(
        IUniswapV3Pool univ3pool,
        uint256 cardinality,
        uint256 period
    ) external view returns (int24 medianTick) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

        (medianTick, ) = PanopticMath.computeMedianObservedPrice(
            univ3pool,
            observationIndex,
            observationCardinality,
            cardinality,
            period
        );
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values.
    /// @dev Also inserts the latest Uniswap observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param period The minimum time in seconds that must have passed since the last observation was inserted into the buffer
    /// @param medianData The packed structure representing the sorted 8-slot queue of ticks
    /// @param univ3pool The Uniswap pool to retrieve observations from
    /// @return The median of the provided 8-slot queue of ticks in `medianData`
    /// @return The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    function computeInternalMedian(
        uint256 period,
        uint256 medianData,
        IUniswapV3Pool univ3pool
    ) external view returns (int24, uint256) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

        return
            PanopticMath.computeInternalMedian(
                observationIndex,
                observationCardinality,
                period,
                medianData,
                univ3pool
            );
    }

    /// @notice Computes the twap of a Uniswap V3 pool using data from its oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window.
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages.
    /// @param univ3pool The Uniswap pool from which to compute the TWAP.
    /// @param twapWindow The time window to compute the TWAP over.
    /// @return The final calculated TWAP tick.
    function twapFilter(IUniswapV3Pool univ3pool, uint32 twapWindow) external view returns (int24) {
        return PanopticMath.twapFilter(univ3pool, twapWindow);
    }

    /// @notice Calculate NAV of user's option portfolio with respect to Uniswap liquidity at a given tick.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick The tick to calculate the value at
    /// @param positionIdList A list of all positions the user holds on that pool
    /// @return value0 The amount of token0 owned by portfolio
    /// @return value1 The amount of token1 owned by portfolio
    function getPortfolioValue(
        PanopticPool pool,
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList
    ) external view returns (int256 value0, int256 value1) {
        // Compute premia for all options (includes short+long premium)
        (, , uint256[2][] memory positionBalanceArray) = pool.getAccumulatedFeesAndPositionsData(
            account,
            false,
            positionIdList
        );

        for (uint256 k = 0; k < positionIdList.length; ) {
            TokenId tokenId = positionIdList[k];
            uint128 positionSize = LeftRightUnsigned.wrap(positionBalanceArray[k][1]).rightSlot();
            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );

                (uint256 amount0, uint256 amount1) = Math.getAmountsForLiquidity(
                    atTick,
                    liquidityChunk
                );

                if (tokenId.isLong(leg) == 0) {
                    unchecked {
                        value0 += int256(amount0);
                        value1 += int256(amount1);
                    }
                } else {
                    unchecked {
                        value0 -= int256(amount0);
                        value1 -= int256(amount1);
                    }
                }

                unchecked {
                    ++leg;
                }
            }
            unchecked {
                ++k;
            }
        }
    }

    /// @notice Computes the minimum position size `account` must hold for `tokenId`.
    /// @dev The constraint that this method applies is that reducing the current position size to the returned value
    /// should not decrease sell-side liquidity in any given chunk such that liquidity utilisation exceeds 90%.
    /// @param pool The `PanopticPool` the supplied position exists on
    /// @param account The address of the account to evaluate
    /// @param tokenId The position to reduce the size of
    /// @return minPositionSize The minimum position size of `tokenId` that `account` must hold
    function computeMinimumSize(
        PanopticPool pool,
        address account,
        TokenId tokenId
    ) external view returns (uint128 minPositionSize) {
        // If there are are no short legs, you can hold as little of this position as you like.
        if (tokenId.countLongs() == tokenId.countLegs()) return 0;

        uint128 preReductionPositionSize;
        {
            TokenId[] memory suppliedPositions = new TokenId[](1);
            suppliedPositions[0] = tokenId;
            (, , uint256[2][] memory positionDataForSuppliedPositions) = pool
                .getAccumulatedFeesAndPositionsData(account, false, suppliedPositions);
            preReductionPositionSize = PositionBalance
                .wrap(
                    // The only position in the list's second item,
                    // which should be the PositionBalance
                    // (first item is the corresponding tokenId)
                    positionDataForSuppliedPositions[0][1]
                )
                .positionSize();
        }

        for (uint256 i = 0; i < tokenId.countLegs(); ) {
            if (tokenId.isLong(i) == 0) {
                uint128 thisLegsMinPositionSize = _computeMinSizeForLeg(
                    pool,
                    tokenId,
                    i,
                    preReductionPositionSize
                );

                if (thisLegsMinPositionSize > minPositionSize) {
                    minPositionSize = thisLegsMinPositionSize;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Computes the minimum required size for a particular leg of a position,
    /// ensuring that after reduction, the buy-side demand does not exceed 90%
    /// of the available sell-side supply.
    /// @param pool The `PanopticPool` the position exists on
    /// @param tokenId The position with a leg to reduce the size of
    /// @param legIndex The index of the leg to reduce the size of within the tokenId
    /// @param currentSize The current position size
    /// @return The minimum position size required for the given leg to maintain liquidity constraints
    function _computeMinSizeForLeg(
        PanopticPool pool,
        TokenId tokenId,
        uint256 legIndex,
        uint128 currentSize
    ) internal view returns (uint128) {
        (int24 legTickLower, int24 legTickUpper) = tokenId.asTicks(legIndex);
        
        LeftRightUnsigned legsChunkLiquidityData = SFPM.getAccountLiquidity(
            address(SFPM.getUniswapV3PoolFromId(tokenId.poolId())),
            address(pool),
            tokenId.tokenType(legIndex),
            legTickLower,
            legTickUpper
        );
        
        // The minimum total sell-side supply is the buy-side demand divided by 90%
        // (Panoptic requires 10% cushion of seller volume to buyer volume)
        // And therefore, your position size can be reduced to:
        // the minimum sell-side volume *minus* the amount others were selling pre-reduction
        return
            _calculateRequiredSaleSize(
                legTickLower,
                legTickUpper,
                tokenId.asset(legIndex),
                tokenId.optionRatio(legIndex),
                // Pass in buysideDemand as the removedLiquidity, which is in the left slot of the liq data:
                legsChunkLiquidityData.leftSlot(),
                // Pass in preexistingSellsideLiquidity as the amount others are currently selling, which is:
                // total being sold pre-reduction (e.g. netLiquidity + removedLiquidity), minus this leg's liquidity
                legsChunkLiquidityData.rightSlot() +
                    legsChunkLiquidityData.leftSlot() -
                    PanopticMath.getLiquidityChunk(tokenId, legIndex, currentSize).liquidity()
            );
    }

    /// @notice Prepares a tokenId and position size to sell such that you may mint the supplied tokenId
    /// in the supplied position size and ensure none of its long legs use up too much of the sell-side supply.
    /// @dev Specifically, we ensure the buy-side demand added by the supplied tokenId does not push liquidity
    /// utilisation above 90%, and add a leg to sell into that chunk if it would.
    /// @param pool the PanopticPool the supplied position exists on
    /// @param tokenId the tokenId with long legs we must ensure are able to buy
    /// @param positionSize the position size the caller plans to purchase this tokenId in
    /// @return sellsidePosition a position you can sell to ensure the long legs in tokenId can buy
    /// @return sellsidePositionSize the position size to sell the sellsidePosition in
    function computeSoldPositionToSatisfyLongLegs(
        PanopticPool pool,
        TokenId tokenId,
        uint128 positionSize
    ) external view returns (TokenId sellsidePosition, uint128 sellsidePositionSize) {
        sellsidePosition = TokenId.wrap(0).addPoolId(tokenId.poolId());

        for (uint256 i = 0; i < tokenId.countLegs(); ) {
            if (tokenId.isLong(i) == 1) {
                (int24 legTickLower, int24 legTickUpper) = tokenId.asTicks(i);

                LeftRightUnsigned legsChunkLiquidityData;
                {
                    legsChunkLiquidityData = SFPM.getAccountLiquidity(
                        address(SFPM.getUniswapV3PoolFromId(tokenId.poolId())),
                        address(pool),
                        tokenId.tokenType(i),
                        legTickLower,
                        legTickUpper
                    );
                }

                uint128 additionalDemand;
                {
                    LiquidityChunk chunk = PanopticMath.getLiquidityChunk(tokenId, i, positionSize);
                    additionalDemand = chunk.liquidity();
                }

                uint128 requiredToSellIntoThisChunk = _calculateRequiredSaleSize(
                    legTickLower,
                    legTickUpper,
                    tokenId.asset(i),
                    1,
                    // calculate the size required for:
                    // current buy-side demand (which is removedLiquidity, the left slot of the liq data)
                    // + the demand the remint would add
                    legsChunkLiquidityData.leftSlot() + additionalDemand,
                    // preexistingSellsideLiquidity is just whatever's being sold right now
                    legsChunkLiquidityData.rightSlot() + legsChunkLiquidityData.leftSlot()
                );

                if (requiredToSellIntoThisChunk > 0) {
                    sellsidePosition = _addLegSellingTo(tokenId, i, sellsidePosition);

                    sellsidePositionSize = requiredToSellIntoThisChunk > sellsidePositionSize
                        ? requiredToSellIntoThisChunk
                        : sellsidePositionSize;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Helper function to calculate the required position size to sell into a specific chunk.
    /// @param tickLower Lower tick of the chunk in question
    /// @param tickUpper Upper tick of the chunk in question
    /// @param asset The asset to return a position size in
    /// @param optionRatio The option ratio to use when converting liquidity to position size
    /// @param buysideDemand The total buying pressure we need to account for
    /// @param preexistingSellsideLiquidity Existing sell-side liquidity to subtract from requirement
    /// @return requiredSize The position size needed to maintain liquidity threshold
    function _calculateRequiredSaleSize(
        int24 tickLower,
        int24 tickUpper,
        uint256 asset,
        uint256 optionRatio,
        uint128 buysideDemand,
        uint128 preexistingSellsideLiquidity
    ) internal pure returns (uint128 requiredSize) {
        // Panoptic requires 10% cushion of seller volume to buyer volume
        // Therefore, the minimum total sell-side supply is that buy-side demand divided by 90%
        uint128 minTotalSellsideLiquidity = uint128(Math.mulDivRoundingUp(buysideDemand, 10, 9));

        if (minTotalSellsideLiquidity <= preexistingSellsideLiquidity) return 0;

        uint128 liquidityToSell = minTotalSellsideLiquidity - preexistingSellsideLiquidity;

        requiredSize = uint128(
            asset == 0
                ? Math.unsafeDivRoundingUp(
                    _getAmount0ForLiquidityRoundingUp(
                        Math.getSqrtRatioAtTick(tickLower),
                        Math.getSqrtRatioAtTick(tickUpper),
                        liquidityToSell
                    ),
                    optionRatio
                )
                : Math.unsafeDivRoundingUp(
                    _getAmount1ForLiquidityRoundingUp(
                        Math.getSqrtRatioAtTick(tickLower),
                        Math.getSqrtRatioAtTick(tickUpper),
                        liquidityToSell
                    ),
                    optionRatio
                )
        );
    }

    /// @notice Adds a corresponding selling leg to an existing position, mirroring the asset and chunk
    /// of a specified long leg within another position.
    /// @dev Takes a position with a known long leg (identified by `positionWithLongLeg` and `longLegIndex`)
    /// and creates a selling leg (short) with matching parameters onto `positionToAddOnto`.
    /// @param positionWithLongLeg The position token containing the referenced long leg
    /// @param longLegIndex The index within `positionWithLongLeg` specifying which leg to replicate as a short leg
    /// @param positionToAddOnto The position token to which the new short leg will be added
    /// @return The updated TokenId after adding the selling leg
    function _addLegSellingTo(
        TokenId positionWithLongLeg,
        uint256 longLegIndex,
        TokenId positionToAddOnto
    ) internal pure returns (TokenId) {
        // Add a leg selling what we need to sell onto sellsidePosition:
        return
            positionToAddOnto.addLeg(
                // legIndex: add it onto the end (which is countLegs() if any non-zero legs already exist; otherwise its 0)
                positionToAddOnto.countLegs(),
                // optionRatio of 1; will make it easier to get equivalentPosition if caller needs
                1,
                // asset: same asset as original
                positionWithLongLeg.asset(longLegIndex),
                // isLong: 0, we want to sell into this chunk to ensure the reminted long leg can buy
                0,
                // tokenType: same tokenType as original
                positionWithLongLeg.tokenType(longLegIndex),
                // riskPartner: no risk partner, just a simple sale
                0,
                // Same strike and width as original
                positionWithLongLeg.strike(longLegIndex),
                positionWithLongLeg.width(longLegIndex)
            );
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range, rounding up.
    /// @dev This is simply Uni's LiquidityAmounts.getAmount0ForLiquidity but using mulDivRoundingUp.
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function _getAmount0ForLiquidityRoundingUp(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        unchecked {
            if (sqrtRatioAX96 > sqrtRatioBX96)
                (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

            return
                FullMath.mulDivRoundingUp(
                    uint256(liquidity) << FixedPoint96.RESOLUTION,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    sqrtRatioBX96
                ) / sqrtRatioAX96;
        }
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range, rounding up.
    /// @dev This is simply Uni's LiquidityAmounts.getAmount1ForLiquidity but using mulDivRoundingUp.
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function _getAmount1ForLiquidityRoundingUp(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        unchecked {
            return
                FullMath.mulDivRoundingUp(
                    liquidity,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    FixedPoint96.Q96
                );
        }
    }

    /// @notice Fetch data about chunks in a positionIdList.
    /// @param account The address of the account to retrieve liquidity data for
    /// @param positionIdList List of TokenIds to evaluate
    /// @return chunkData A [2][4][positionIdList.length] array containing netLiquidity and removedLiquidity for each leg
    function getChunkData(
        address account,
        TokenId[] memory positionIdList
    ) external view returns (uint256[2][4][] memory) {
        uint256[2][4][] memory chunkData = new uint256[2][4][](positionIdList.length);

        for (uint256 i; i < positionIdList.length; ) {
            for (uint256 j; j < positionIdList[i].countLegs(); ) {
                (int24 tickLower, int24 tickUpper) = positionIdList[i].asTicks(j);
                LeftRightUnsigned liquidityData = SFPM.getAccountLiquidity(
                    address(SFPM.getUniswapV3PoolFromId(positionIdList[i].poolId())),
                    account,
                    positionIdList[i].tokenType(j),
                    tickLower,
                    tickUpper
                );

                // net liquidity:
                chunkData[i][j][0] = liquidityData.rightSlot();
                // removed liquidity:
                chunkData[i][j][1] = liquidityData.leftSlot();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        return chunkData;
    }

    /// @notice Calculate approximate NLV of user's option portfolio (token delta after closing `positionIdList`) at a given tick.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param includePendingPremium If true, include premium that is owed to the user but has not yet settled; if false, only include premium that is available to collect
    /// @param positionIdList A list of all positions the user holds on that pool
    /// @param atTick The tick to calculate the value at
    /// @return value0 The NLV of `positionIdList` owned by `account` at the price `atTick` in terms of token0
    /// @return value1 The NLV of `positionIdList` owned by `account` at the price `atTick` in terms of token1
    function getNetLiquidationValue(
        PanopticPool pool,
        address account,
        bool includePendingPremium,
        TokenId[] calldata positionIdList,
        int24 atTick
    ) external view returns (int256 value0, int256 value1) {
        // Compute premia for all options (includes short+long premium)
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, includePendingPremium, positionIdList);

        for (uint256 k = 0; k < positionIdList.length; ) {
            TokenId tokenId = positionIdList[k];
            uint128 positionSize = LeftRightUnsigned.wrap(positionBalanceArray[k][1]).rightSlot();
            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );

                (uint256 amount0, uint256 amount1) = Math.getAmountsForLiquidity(
                    atTick,
                    liquidityChunk
                );

                if (tokenId.isLong(leg) == 0) {
                    unchecked {
                        value0 += int256(amount0);
                        value1 += int256(amount1);
                    }
                } else {
                    unchecked {
                        value0 -= int256(amount0);
                        value1 -= int256(amount1);
                    }
                }

                unchecked {
                    ++leg;
                }
            }

            (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
                .computeExercisedAmounts(tokenId, positionSize);

            value0 += int256(longAmounts.rightSlot()) - int256(shortAmounts.rightSlot());
            value1 += int256(longAmounts.leftSlot()) - int256(shortAmounts.leftSlot());

            unchecked {
                ++k;
            }
        }

        value0 +=
            int256(uint256(shortPremium.rightSlot())) -
            int256(uint256(longPremium.rightSlot()));
        value1 +=
            int256(uint256(shortPremium.leftSlot())) -
            int256(uint256(longPremium.leftSlot()));
    }
}
