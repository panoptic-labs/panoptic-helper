// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
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
    using Math for uint256;

    uint256 internal constant DECIMALS = 10_000;
    uint256 internal NO_BUFFER = 10_000_000;

    /// @notice The SemiFungiblePositionManager of the Panoptic instance this querying helper is intended for.
    ISemiFungiblePositionManager internal immutable SFPM;

    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;

    int24 constant TICK_PRECISION = 1;

    /// @notice Construct the PanopticQuery and store the SFPM address.
    /// @param SFPM_ The canonical SFPM address for the Panoptic instance this helper queries
    constructor(ISemiFungiblePositionManager SFPM_) payable {
        SFPM = SFPM_;
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance0 The total combined balance of token0 and token1 for a user in terms of token0
    /// @return requiredCollateral0 The combined collateral requirement for a user in terms of token0
    function checkCollateral(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        int24 atTick
    ) public view returns (uint256, uint256) {
        // Compute premia for all options (includes short+long premium)
        (
            LeftRightUnsigned tokenData0,
            LeftRightUnsigned tokenData1,
            PositionBalance globalUtilizations
        ) = _getMargin(pool, atTick, account, positionIdList);
        uint256 utilization0;
        uint256 utilization1;
        {
            PanopticPool _pool = pool;
            uint256 crossBuffer0 = _pool.riskEngine().CROSS_BUFFER_0();
            uint256 crossBuffer1 = _pool.riskEngine().CROSS_BUFFER_1();
            utilization0 = _crossBufferRatio(
                _pool,
                globalUtilizations.utilization0(),
                crossBuffer0
            );
            utilization1 = _crossBufferRatio(
                _pool,
                globalUtilizations.utilization1(),
                crossBuffer1
            );
        }

        uint256 maintReq0 = Math.mulDivRoundingUp(tokenData0.leftSlot(), NO_BUFFER, DECIMALS);
        uint256 maintReq1 = Math.mulDivRoundingUp(tokenData1.leftSlot(), NO_BUFFER, DECIMALS);

        uint256 bal0 = tokenData0.rightSlot();
        uint256 bal1 = tokenData1.rightSlot();

        uint256 scaledSurplusToken0 = Math.mulDiv(
            bal0 > maintReq0 ? bal0 - maintReq0 : 0,
            utilization0,
            DECIMALS
        );
        uint256 scaledSurplusToken1 = Math.mulDiv(
            bal1 > maintReq1 ? bal1 - maintReq1 : 0,
            utilization1,
            DECIMALS
        );

        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(atTick);

        uint256 effectiveBal0;
        uint256 effectiveReq0;
        uint256 effectiveBal1;
        uint256 effectiveReq1;
        if (sqrtPriceX96 < Constants.FP96) {
            effectiveBal0 = bal0 + PanopticMath.convert1to0(scaledSurplusToken1, sqrtPriceX96);
            effectiveReq0 = maintReq0;
            effectiveBal1 = PanopticMath.convert1to0(bal1, sqrtPriceX96) + scaledSurplusToken0;
            effectiveReq1 = PanopticMath.convert1to0RoundingUp(maintReq1, sqrtPriceX96);
        } else {
            effectiveBal0 = PanopticMath.convert0to1(bal0, sqrtPriceX96) + scaledSurplusToken1;
            effectiveReq0 = PanopticMath.convert0to1RoundingUp(maintReq0, sqrtPriceX96);
            effectiveBal1 = bal1 + PanopticMath.convert0to1(scaledSurplusToken0, sqrtPriceX96);
            effectiveReq1 = maintReq1;
        }

        //return (effectiveBal0, effectiveReq0, effectiveBal1, effectiveReq1);
    }

    function _crossBufferRatio(
        PanopticPool pool,
        int256 utilization,
        uint256 crossBuffer
    ) internal view returns (uint256 crossBufferRatio) {
        crossBufferRatio = pool.riskEngine().crossBufferRatio(utilization, crossBuffer);
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return solvent A boolean flag on whether the account is solvent (true)
    function isAccountSolvent(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        int24 atTick
    ) public view returns (bool) {
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        CollateralTracker ct0 = pool.collateralToken0();
        CollateralTracker ct1 = pool.collateralToken1();

        return (
            pool.riskEngine().isAccountSolvent(
                positionBalanceArray,
                positionIdList,
                atTick,
                account,
                shortPremium,
                longPremium,
                ct0,
                ct1,
                10_000_000
            )
        );
    }

    function _getMargin(
        PanopticPool pool,
        int24 atTick,
        address account,
        TokenId[] calldata positionIdList
    )
        internal
        view
        returns (
            LeftRightUnsigned tokenData0,
            LeftRightUnsigned tokenData1,
            PositionBalance globalUtilizations
        )
    {
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        CollateralTracker ct0 = pool.collateralToken0();
        CollateralTracker ct1 = pool.collateralToken1();

        //TokenId[] memory _positionIdList = positionIdList;

        // Query the current and required collateral amounts for the two tokens
        (tokenData0, tokenData1, globalUtilizations) = pool.riskEngine().getMargin(
            positionBalanceArray,
            atTick,
            account,
            positionIdList,
            LeftRightUnsigned.wrap(0), //shortPremium,
            LeftRightUnsigned.wrap(0), //longPremium,
            ct0,
            ct1
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
            (collateralBalances0[i], requiredCollaterals0[i]) = checkCollateral(
                pool,
                account,
                positionIdList,
                ticks[i]
            );
        }
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList at currentTick and finds the liquidation price(s).
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance0 The total combined balance of token0 and token1 for a user in terms of token0
    /// @return requiredCollateral0 The combined collateral requirement for a user in terms of token0
    /// @return collateralBalance1 The total combined balance of token0 and token1 for a user in terms of token1
    /// @return requiredCollateral1 The combined collateral requirement for a user in terms of token1
    /// @return liquidationPriceDown The liquidation price below currentTick (returns type(int24).min if none)
    /// @return liquidationPriceUp The liquidation price above currentTick (returns type(int24).max if none)
    function checkCollateralAndGetLiquidationPrices(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    )
        public
        view
        returns (
            uint256 collateralBalance0,
            uint256 requiredCollateral0,
            uint256 collateralBalance1,
            uint256 requiredCollateral1,
            int24 liquidationPriceDown,
            int24 liquidationPriceUp
        )
    {
        liquidationPriceUp = type(int24).max;
        liquidationPriceDown = type(int24).min;
        int24 currentTick;
        (currentTick, , , , ) = pool.getOracleTicks();

        (collateralBalance0, requiredCollateral0) = checkCollateral(
            pool,
            account,
            positionIdList,
            currentTick
        );

        {
            if (!isAccountSolvent(pool, account, positionIdList, MIN_TICK)) {
                // There's a liquidation price somewhere below current tick
                liquidationPriceDown = binarySearchDown(
                    pool,
                    account,
                    MIN_TICK,
                    currentTick,
                    positionIdList
                );
            }
        }
        {
            if (!isAccountSolvent(pool, account, positionIdList, MAX_TICK)) {
                // Find liquidation price above current tick (liquidationPriceUp)
                // There's a liquidation price somewhere above current tick
                liquidationPriceUp = binarySearchUp(
                    pool,
                    account,
                    currentTick,
                    MAX_TICK,
                    positionIdList
                );
            }
        }
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList at various prices.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalances The total combined balances and required tokens for the positions list.
    /// @return tickList The list of ticks where each collateral and required quantities are computed at
    /// @return liquidationPrices The liauidation prices on the way up or down
    function checkCollateralListOutput(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (uint256[2][] memory, int256[] memory, int24[] memory) {
        int256[] memory tickData = new int256[](301);
        int24[] memory liquidationPrices = new int24[](2);
        {
            int24 scaledTick;
            int24 tickSpacing;
            {
                (int24 currentTick, , , , ) = pool.getOracleTicks();
                tickSpacing = positionIdList[0].tickSpacing();
                scaledTick = ((currentTick / tickSpacing) * tickSpacing);
            }

            (
                ,
                ,
                ,
                ,
                int24 liquidationPriceDown,
                int24 liquidationPriceUp
            ) = checkCollateralAndGetLiquidationPrices(pool, account, positionIdList);
            liquidationPrices[0] = liquidationPriceDown;
            liquidationPrices[1] = liquidationPriceUp;
            tickData[0] = MIN_TICK;
            tickData[300] = MAX_TICK;

            int24 startTick = scaledTick - int24(25000); // Default start
            int24 endTick = scaledTick + int24(25000); // Default end

            // Expand range to include liquidation prices if they exist
            if ((liquidationPriceDown < startTick) && (liquidationPriceDown != type(int24).min)) {
                startTick = liquidationPriceDown - 10000;
            }
            if ((liquidationPriceUp > endTick) && (liquidationPriceUp != type(int24).max)) {
                endTick = liquidationPriceUp + 10000;
            }

            int256 tickRange = int256(endTick) - int256(startTick);
            int256 step = tickRange / 298; // 298 slots between MIN_TICK and MAX_TICK

            for (uint256 i = 1; i < 300; i++) {
                int256 tick = int256(startTick) + (int256(i - 1) * step);
                // Round to tick spacing
                tickData[i] = (tick / tickSpacing) * tickSpacing;
            }
        }
        uint256[2][] memory balanceRequired = new uint256[2][](301);

        for (uint256 i; i < 301; ) {
            {
                uint256 collateralBalance;
                uint256 requiredCollateral;
                uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(int24(tickData[i]));
                if (tickData[150] < 0) {
                    (collateralBalance, requiredCollateral) = checkCollateral(
                        pool,
                        account,
                        positionIdList,
                        int24(tickData[i])
                    );
                    collateralBalance = (collateralBalance * sqrtPriceX96) >> 96;
                    requiredCollateral = (requiredCollateral * sqrtPriceX96) >> 96;
                } else {
                    (collateralBalance, requiredCollateral) = checkCollateral(
                        pool,
                        account,
                        positionIdList,
                        int24(tickData[i])
                    );
                    collateralBalance = (collateralBalance << 96) / sqrtPriceX96;
                    requiredCollateral = (requiredCollateral << 96) / sqrtPriceX96;
                }

                balanceRequired[i][0] = collateralBalance;
                balanceRequired[i][1] = requiredCollateral;
            }
            ++i;
        }

        return (balanceRequired, tickData, liquidationPrices);
    }

    /**
     * @notice Binary search for liquidation price going down from current tick
     * @dev Finds the tick where collateral transitions from >= required to < required
     */
    function binarySearchDown(
        PanopticPool pool,
        address account,
        int24 lowerBound,
        int24 upperBound,
        TokenId[] calldata positionIdList
    ) internal view returns (int24) {
        while (upperBound - lowerBound > TICK_PRECISION) {
            int24 midTick = (lowerBound + upperBound) / 2;

            bool solvent = isAccountSolvent(pool, account, positionIdList, midTick);

            if (solvent) {
                // Still solvent at midTick, liquidation is lower
                upperBound = midTick;
            } else {
                // Insolvent at midTick, liquidation is higher
                lowerBound = midTick;
            }
        }

        // Return the tick just before insolvency
        return upperBound;
    }

    /**
     * @notice Binary search for liquidation price going up from current tick
     * @dev Finds the tick where collateral transitions from >= required to < required
     */
    function binarySearchUp(
        PanopticPool pool,
        address account,
        int24 lowerBound,
        int24 upperBound,
        TokenId[] calldata positionIdList
    ) internal view returns (int24) {
        while (upperBound - lowerBound > TICK_PRECISION) {
            int24 midTick = (lowerBound + upperBound) / 2;

            bool solvent = isAccountSolvent(pool, account, positionIdList, midTick);

            if (solvent) {
                // Still solvent at midTick, liquidation is higher
                lowerBound = midTick;
            } else {
                // Insolvent at midTick, liquidation is lower
                upperBound = midTick;
            }
        }

        // Return the tick just before insolvency
        return lowerBound;
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
        (, , PositionBalance[] memory positionBalanceArray) = pool
            .getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        for (uint256 k = 0; k < positionIdList.length; ) {
            TokenId tokenId = positionIdList[k];
            uint128 positionSize = positionBalanceArray[k].positionSize();
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
                        value0 += (amount0).toInt256();
                        value1 += (amount1).toInt256();
                    }
                } else {
                    unchecked {
                        value0 -= (amount0).toInt256();
                        value1 -= (amount1).toInt256();
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
            (, , PositionBalance[] memory positionDataForSuppliedPositions) = pool
                .getAccumulatedFeesAndPositionsData(account, false, suppliedPositions);
            preReductionPositionSize = positionDataForSuppliedPositions[0].positionSize();
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
            pool.poolKey(),
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
            calculateRequiredSaleSize(
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
    /// @param pool The `PanopticPool` the supplied position exists on
    /// @param tokenId The tokenId with long legs we must ensure are able to buy
    /// @param positionSize The position size the caller plans to purchase this tokenId in
    /// @return sellsidePosition A position you can sell to ensure the long legs in tokenId can buy
    /// @return sellsidePositionSize The position size to sell the sellsidePosition in
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
                        pool.poolKey(),
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

                uint128 requiredToSellIntoThisChunk = calculateRequiredSaleSize(
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
    function calculateRequiredSaleSize(
        int24 tickLower,
        int24 tickUpper,
        uint256 asset,
        uint256 optionRatio,
        uint128 buysideDemand,
        uint128 preexistingSellsideLiquidity
    ) public pure returns (uint128 requiredSize) {
        // Panoptic requires 10% cushion of seller volume to buyer volume
        // Therefore, the minimum total sell-side supply is that buy-side demand divided by 90%
        uint128 minTotalSellsideLiquidity = uint128(Math.mulDivRoundingUp(buysideDemand, 10, 9));

        if (minTotalSellsideLiquidity <= preexistingSellsideLiquidity) return 0;

        uint128 liquidityToSell = minTotalSellsideLiquidity - preexistingSellsideLiquidity;

        requiredSize = uint128(
            Math.unsafeDivRoundingUp(
                asset == 0
                    ? _getAmount0ForLiquidityRoundingUp(
                        Math.getSqrtRatioAtTick(tickLower),
                        Math.getSqrtRatioAtTick(tickUpper),
                        liquidityToSell
                    )
                    : _getAmount1ForLiquidityRoundingUp(
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
                // legIndex: add it onto the end
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
    /// @param pool The PanopticPool instance containing the positions
    /// @param account The address of the account to retrieve liquidity data for
    /// @param positionIdList List of TokenIds to evaluate
    /// @return chunkData A [2][4][positionIdList.length] array containing netLiquidity and removedLiquidity for each leg
    function getChunkData(
        PanopticPool pool,
        address account,
        TokenId[] memory positionIdList
    ) external view returns (uint256[2][4][] memory) {
        uint256[2][4][] memory chunkData = new uint256[2][4][](positionIdList.length);

        for (uint256 i; i < positionIdList.length; ) {
            for (uint256 j; j < positionIdList[i].countLegs(); ) {
                (int24 tickLower, int24 tickUpper) = positionIdList[i].asTicks(j);
                LeftRightUnsigned liquidityData = SFPM.getAccountLiquidity(
                    pool.poolKey(),
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
            PositionBalance[] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, includePendingPremium, positionIdList);

        for (uint256 k = 0; k < positionIdList.length; ) {
            TokenId tokenId = positionIdList[k];
            uint128 positionSize = positionBalanceArray[k].positionSize();
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
                        value0 += (amount0).toInt256();
                        value1 += (amount1).toInt256();
                    }
                } else {
                    unchecked {
                        value0 -= (amount0).toInt256();
                        value1 -= (amount1).toInt256();
                    }
                }

                unchecked {
                    ++leg;
                }
            }

            (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
                .computeExercisedAmounts(tokenId, positionSize, false);

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

    /// @notice Optimize the risk partnering of all legs within a tokenId.
    /// @param pool The PanopticPool instance to optimize the tokenId for
    /// @param atTick The price at which the collateral requirement is evaluated
    /// @param tokenId the input tokenId
    /// @return the optimized tokenId
    function optimizeRiskPartners(
        PanopticPool pool,
        int24 atTick,
        TokenId tokenId
    ) public view returns (TokenId) {
        uint256 numberOfLegs = tokenId.countLegs();
        if (numberOfLegs == 1) {
            return tokenId;
        } else {
            TokenId _tempTokenId = TokenId.wrap(
                TokenId.unwrap(tokenId) &
                    0xFFFFFFFFF3FFFFFFFFFFF3FFFFFFFFFFF3FFFFFFFFFFF3FFFFFFFFFFFFFFFFFF
            );
            TokenId[] memory tokenIdList;
            uint256 N;

            if (numberOfLegs == 2) {
                N = 2;
                tokenIdList = new TokenId[](N);

                tokenIdList[0] = _tempTokenId.addRiskPartner(0, 0).addRiskPartner(1, 1);
                tokenIdList[1] = _tempTokenId.addRiskPartner(1, 0).addRiskPartner(0, 1);
            } else if (numberOfLegs == 3) {
                N = 4;
                tokenIdList = new TokenId[](N);

                tokenIdList[0] = _tempTokenId
                    .addRiskPartner(0, 0)
                    .addRiskPartner(1, 1)
                    .addRiskPartner(2, 2);

                tokenIdList[1] = _tempTokenId
                    .addRiskPartner(1, 0)
                    .addRiskPartner(0, 1)
                    .addRiskPartner(2, 2);
                tokenIdList[2] = _tempTokenId
                    .addRiskPartner(2, 0)
                    .addRiskPartner(1, 1)
                    .addRiskPartner(0, 2);
                tokenIdList[3] = _tempTokenId
                    .addRiskPartner(0, 0)
                    .addRiskPartner(2, 1)
                    .addRiskPartner(1, 2);
            } else {
                N = 10;
                tokenIdList = new TokenId[](N);

                tokenIdList[0] = _tempTokenId
                    .addRiskPartner(0, 0)
                    .addRiskPartner(1, 1)
                    .addRiskPartner(2, 2)
                    .addRiskPartner(3, 3);

                tokenIdList[1] = _tempTokenId
                    .addRiskPartner(1, 0)
                    .addRiskPartner(0, 1)
                    .addRiskPartner(2, 2)
                    .addRiskPartner(3, 3);
                tokenIdList[2] = _tempTokenId
                    .addRiskPartner(2, 0)
                    .addRiskPartner(1, 1)
                    .addRiskPartner(0, 2)
                    .addRiskPartner(3, 3);
                tokenIdList[3] = _tempTokenId
                    .addRiskPartner(3, 0)
                    .addRiskPartner(1, 1)
                    .addRiskPartner(2, 2)
                    .addRiskPartner(0, 3);

                tokenIdList[4] = _tempTokenId
                    .addRiskPartner(0, 0)
                    .addRiskPartner(2, 1)
                    .addRiskPartner(1, 2)
                    .addRiskPartner(3, 3);
                tokenIdList[5] = _tempTokenId
                    .addRiskPartner(0, 0)
                    .addRiskPartner(3, 1)
                    .addRiskPartner(2, 2)
                    .addRiskPartner(1, 3);
                tokenIdList[6] = _tempTokenId
                    .addRiskPartner(0, 0)
                    .addRiskPartner(1, 1)
                    .addRiskPartner(3, 2)
                    .addRiskPartner(2, 3);

                tokenIdList[7] = _tempTokenId
                    .addRiskPartner(1, 0)
                    .addRiskPartner(0, 1)
                    .addRiskPartner(3, 2)
                    .addRiskPartner(2, 3);
                tokenIdList[8] = _tempTokenId
                    .addRiskPartner(2, 0)
                    .addRiskPartner(3, 1)
                    .addRiskPartner(0, 2)
                    .addRiskPartner(1, 3);
                tokenIdList[9] = _tempTokenId
                    .addRiskPartner(3, 0)
                    .addRiskPartner(2, 1)
                    .addRiskPartner(0, 2)
                    .addRiskPartner(0, 3);
            }

            uint256 lowestCollateralRequirement = this.getRequiredBase(
                pool,
                tokenIdList[0],
                atTick
            );
            TokenId lowestTokenId = tokenIdList[0];

            for (uint256 i = 1; i < N; ++i) {
                try this.getRequiredBase(pool, tokenIdList[i], atTick) returns (
                    uint256 _collateralRequirement
                ) {
                    if (_collateralRequirement < lowestCollateralRequirement) {
                        lowestTokenId = tokenIdList[i];
                        lowestCollateralRequirement = _collateralRequirement;
                    }
                } catch {}
            }
            return lowestTokenId;
        }
    }

    /// @notice An external function that returns the collateral needed for a single tokenId at the provided tick.
    /// @param pool The PanopticPool instance to optimize the tokenId for
    /// @param atTick The price at which the collateral requirement is evaluated
    /// @param tokenId the input tokenId
    /// @return the required collateral for that position in terms of token0
    function getRequiredBase(
        PanopticPool pool,
        TokenId tokenId,
        int24 atTick
    ) external view returns (uint256) {
        try this.validateTokenId(tokenId) {
            PositionBalance[] memory positionBalanceArray = new PositionBalance[](1);
            TokenId[] memory positionIdList = new TokenId[](1);

            positionIdList[0] = tokenId;
            // Create a synthetic position balance with type(uint104).max size and max utilization
            positionBalanceArray[0] = PositionBalanceLibrary.storeBalanceData(
                type(uint64).max,
                10000 + (10000 << 16),
                0,
                0,
                0,
                false
            );

            try
                pool.riskEngine().getMargin(
                    positionBalanceArray,
                    atTick,
                    address(0xdead),
                    positionIdList,
                    LeftRightUnsigned.wrap(0),
                    LeftRightUnsigned.wrap(0),
                    pool.collateralToken0(),
                    pool.collateralToken1()
                )
            returns (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, PositionBalance) {
                (, uint256 required0) = PanopticMath.getCrossBalances(
                    tokenData0,
                    tokenData1,
                    Math.getSqrtRatioAtTick(atTick)
                );

                return required0;
            } catch {
                return type(uint128).max;
            }
        } catch {
            return type(uint128).max;
        }
    }

    /// @notice An external function that validates a tokenId.
    /// @param self the tokenId to be tested
    function validateTokenId(TokenId self) external pure {
        self.validate();
        for (uint256 leg; leg < self.countLegs(); ++leg) {
            self.asTicks(leg);
        }
    }

    /// @notice An external function that ensures that the proposed tokenId can be minted.
    /// @param tokenId the input tokenId
    /// @param positionSize the size of the position
    /// @return a boolean value, valid = true / invalid = false
    function checkTokenId(TokenId tokenId, uint128 positionSize) internal pure returns (bool) {
        for (uint256 legIndex; legIndex < tokenId.countLegs(); ++legIndex) {
            LeftRightUnsigned amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                positionSize,
                legIndex,
                false
            );

            if (
                (amountsMoved.rightSlot() > type(uint120).max) ||
                (amountsMoved.leftSlot() > type(uint120).max)
            ) {
                return false;
            }
        }
        return true;
    }
}
