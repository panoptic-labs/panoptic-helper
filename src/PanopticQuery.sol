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
import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticQuery {
    /// @notice The SemiFungiblePositionManager of the Panoptic instance this querying helper is intended for.
    SemiFungiblePositionManager internal immutable SFPM;
    /// @notice A TokenIdHelper used to unwrap TokenIds into the leg data they represent.
    TokenIdHelper internal immutable tokenIdHelper;

    /// @notice Construct the PanopticQuery and store the SFPM and TokenIdHelper addresses.
    /// @param SFPM_ The canonical SFPM address for the Panoptic instance this helper queries
    /// @param tokenIdHelper_ A TokenIdHelper that can unwrap tokenIds into legs
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

    /// @notice Calculates the minimum legal position size that the account could be holding for the supplied position.
    /// @dev The only constraint this method currently considers is that the notional amount purchased in the chunk
    /// remains <= 90% of the notional amount being sold.
    /// @param account The address of the account to evaluate
    /// @param pool The PanopticPool the supplied position exists on
    /// @param tokenId The position to reduce the size of
    /// @return The minimum position size that `account` could hold `tokenId` in
    function reduceSizeIfNecessary(
        PanopticPool pool,
        address account,
        TokenId tokenId
    ) external view returns (uint128) {
        // If there are are no short legs, you can hold as much of this position as you like.
        // TODO: maybe more gas efficient to reuse minNetLiquidity as return val here?
        if (tokenId.countLongs() == tokenId.countLegs()) return type(uint128).max;

        // TODO: shorter var name
        LeftRightUnsigned liquidityDataForChunkWithSmallestNetLiquidity = 0;
        TokenIdHelper.Leg[] memory legs = tokenIdHelper.unwrapTokenId(tokenId);
        TokenIdHelper.Leg mostConstrainedLeg;
        for (uint256 i = 0; i < tokenId.countLegs(); ) {
            if (legs[i].isLong == 0) {
                LeftRightUnsigned liquidityDataForLegsChunk = SFPM.getAccountLiquidity(
                    legs[i].UniswapV3Pool,
                    account,
                    legs[i].tokenType,
                    legs[i].strike - (legs[i].width / 2),
                    legs[i].strike + (legs[i].width / 2)
                );

                // liquidityDataForLegsChunk.rightSlot() = netLiquidity
                if (liquidityDataForLegsChunk.rightSlot() < liquidityDataForChunkWithSmallestNetLiquidity.rightSlot() || legIndex = 0) {
                    liquidityDataForChunkWithSmallestNetLiquidity = liquidityDataForLegsChunk;
                    mostConstrainedLeg = legs[i];
                }
            }
            unchecked {
                ++i;
            }
        }

        // removedLiquidity is equivalent to the amount of long demand
        // Therefore, our min position size is that long demand divided by 90%
        // (Panoptic requires 10% cushion of seller volume to buyer volume)
        // TODO: I believe we could also calculate how much is currently being sold by other sellers
        // in the chunk, somewhere above, and then subtract that from liquidityToSell too and reduce
        // size even further. For now, proceeding with a version that assumes you're the only seller.
        uint128 liquidityToSell = Math.mulDivRoundingUp(
            liquidityDataForChunkWithSmallestNetLiquidity.leftSlot(),
            10,
            9
        );
        // Convert to asset-token denomination to return a position size
        LiquidityChunk liquidityChunk = LiquidityChunkLibrary.createChunk(
            mostConstrainedLeg.strike - (mostConstrainedLeg.width / 2),
            mostConstrainedLeg.strike + (mostConstrainedLeg.width / 2),
            liquidityToSell
        );
        return
            mostConstrainedLeg.asset == 0
                ? Math.getAmount0ForLiquidity(liquidityChunk)
                : Math.getAmount1ForLiquidity(liquidityChunk);
    }

    /// @notice Fetch data about chunks in a positionIdList.
    /// @param account The address of the account to retrieve liquidity data for
    /// @param positionIdList List of TokenIds to evaluate
    /// @return chunkData A [positionIdList.length][4][2] array containing netLiquidity and removedLiquidity for each leg
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
