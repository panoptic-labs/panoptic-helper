// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {TokenIdHelper} from "@helper/TokenIdHelper.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
// Custom types
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticQuery {
    SemiFungiblePositionManager internal immutable SFPM;
    TokenIdHelper internal immutable tokenIdHelper;

    /// @notice Construct the PanopticHelper contract
    /// @param SFPM_ address of the SemiFungiblePositionManager
    /// @param tokenIdHelper_ address of the TokenIdHelper to leverage
    constructor(SemiFungiblePositionManager SFPM_, TokenIdHelper tokenIdHelper_) payable {
        SFPM = SFPM_;
        tokenIdHelper = tokenIdHelper_;
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

    /// @notice Calculate NAV of user's option portfolio at a given tick.
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

    /// @notice Evaluates if the supplied position has enough liquidity to be burnt successfully:
    /// - if it does, returns the supplied position size
    /// - if not, returns a new position size that keeps usage of net liquidity under a supplied limit
    /// @param account The address of the account to evaluate
    /// @param pool The PanopticPool the supplied position exists on
    /// @param tokenId The TokenId to reduce the size of
    /// @param netLiquidityUsageLimitBPS When readusting, the proportion of net liquidity to limit
    /// the new position size to using
    /// @return newPositionSize A position size that ensures you don't exceed the supplied net liquidity usage limit
    function reduceSizeIfNecessary(
        PanopticPool pool,
        address account,
        TokenId tokenId,
        uint128 netLiquidityUsageLimitBPS
    ) external view returns (uint128 newPositionSize) {
        TokenIdHelper.Leg[] memory legs = tokenIdHelper.unwrapTokenId(tokenId);

        TokenId[] memory accountsPositionsToGetSizesFor = new TokenId[](1);
        accountsPositionsToGetSizesFor[0] = tokenId;
        (, , uint256[2][] memory existingPositions) = pool.getAccumulatedFeesAndPositionsData(
            account,
            false,
            accountsPositionsToGetSizesFor
        );
        uint128 oldPositionSize = PositionBalance
            .wrap(
                // The only position in the list's second item,
                // which should be the PositionBalance
                // (first item is the corresponding tokenId)
                existingPositions[0][1]
            )
            .positionSize();

        // If there are are no longs; sell as much as you're currently selling.
        // (TODO: could be more sophisticated and return the
        // actual limit on how much you can sell for this case, even above oldPositionSize)
        // Else, we'll start with the current position size as a max to reduce as need be.
        newPositionSize = oldPositionSize;
        if (tokenId.countLongs() > 0) {
            // Iterate over each leg and determine if there is enough netLiquidity to burn it.
            for (uint256 i = 0; i < tokenId.countLegs(); ) {
                if (legs[i].isLong == 1) {
                    LeftRightUnsigned liquidityData = SFPM.getAccountLiquidity(
                        legs[i].UniswapV3Pool,
                        account,
                        legs[i].tokenType,
                        legs[i].strike - (legs[i].width / 2),
                        legs[i].strike + (legs[i].width / 2)
                    );
                    uint128 netLiquidity = liquidityData.rightSlot();

                    if (newPositionSize * legs[i].optionRatio > netLiquidity) {
                        // If not enough liquidity, lower position size to keep util at
                        // requested limit
                        newPositionSize = uint128(
                            (netLiquidity * netLiquidityUsageLimitBPS) /
                                uint128(10_000) /
                                legs[i].optionRatio
                        );
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Fetch data about chunks in a positionIdList.
    /// @param account The address of the account to retrieve liquidity data for
    /// @param positionIdList List of TokenIds to evaluate
    /// @return chunkData A memory array of [positionIdList.length][4][2] containing netLiquidity and removedLiquidity for each leg
    function getChunkData(
        address account,
        TokenId[] memory positionIdList
    ) external view returns (uint256[][][] memory) {
        uint256[][][] memory chunkData = new uint256[][][](positionIdList.length);

        for (uint256 i; i < positionIdList.length; ) {
            uint256[][] memory ithPositionLiquidities = new uint256[][](4);

            for (uint256 j; j < positionIdList[i].countLegs(); ) {
                LeftRightUnsigned liquidityData = SFPM.getAccountLiquidity(
                    address(SFPM.getUniswapV3PoolFromId(positionIdList[i].poolId())),
                    account,
                    positionIdList[i].tokenType(j),
                    positionIdList[i].strike(j) - (positionIdList[i].width(j) / 2),
                    positionIdList[i].strike(j) + (positionIdList[i].width(j) / 2)
                );

                uint256[] memory liquidityDataArr = new uint256[](2);
                // net liquidity:
                liquidityDataArr[0] = liquidityData.rightSlot();
                // removed liquidity:
                liquidityDataArr[1] = liquidityData.leftSlot();
                ithPositionLiquidities[j] = liquidityDataArr;

                unchecked {
                    ++j;
                }
            }

            chunkData[i] = ithPositionLiquidities;
            unchecked {
                ++i;
            }
        }

        return chunkData;
    }
}
