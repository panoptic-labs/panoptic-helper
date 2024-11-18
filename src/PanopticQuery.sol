// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
// Custom types
import {LeftRightSigned, LeftRightUnsigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticQuery {
    /*//////////////////////////////////////////////////////////////
                          POSITION INFO
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total number of contracts owned by `account` and the pool utilization at mint for a specified `tokenId.
    /// @param pool The PanopticPool instance corresponding to the pool specified in `TokenId`
    /// @param account The address of the account on which to retrieve `balance` and `poolUtilization`
    /// @return balance Number of contracts of `tokenId` owned by the user
    /// @return poolUtilization0 The utilization of token0 in the Panoptic pool at mint
    /// @return poolUtilization1 The utilization of token1 in the Panoptic pool at mint
    function optionPositionInfo(
        PanopticPool pool,
        address account,
        TokenId tokenId
    ) external view returns (uint128, uint64, uint64) {
        TokenId[] memory tokenIdList = new TokenId[](1);
        tokenIdList[0] = tokenId;

        (, , uint256[2][] memory positionBalanceArray) = pool.getAccumulatedFeesAndPositionsData(
            account,
            false,
            tokenIdList
        );

        LeftRightUnsigned balanceAndUtilization = LeftRightUnsigned.wrap(
            positionBalanceArray[0][1]
        );

        return (
            balanceAndUtilization.rightSlot(),
            uint64(balanceAndUtilization.leftSlot()),
            uint64(balanceAndUtilization.leftSlot() >> 64)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          COLLATERAL QUERIES
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Compute the buying power requirement of positions in an account on a PanopticPool.
    /// @param pool The PanopticPool instance to return buying power requirement within
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return buyingPowerRequirement0 The buying power requirement of the account in terms of token0 at the current price
    /// @return buyingPowerRequirement1 The buying power requirement of the account in terms of token1 at the current price
    function buyingPowerRequirement(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (uint256 buyingPowerRequirement0, uint256 buyingPowerRequirement1) {
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.univ3pool().slot0();

        (, buyingPowerRequirement0, , buyingPowerRequirement1) = checkCollateral(
            pool,
            account,
            tick,
            positionIdList
        );
    }

    /// @notice Compute the buying power of positions in an account on a PanopticPool.
    /// @param pool The PanopticPool instance to return buying power within
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return buyingPower0 The buying power of the account in terms of token0 at the current price
    /// @return buyingPower1 The buying power of the account in terms of token1 at the current price
    function buyingPower(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int256 buyingPower0, int256 buyingPower1) {
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.univ3pool().slot0();

        (
            uint256 balance0,
            uint256 required0,
            uint256 balance1,
            uint256 required1
        ) = checkCollateral(pool, account, tick, positionIdList);

        buyingPower0 = int256(balance0) - int256(required0);
        buyingPower1 = int256(balance1) - int256(required1);
    }

    /// @notice Compute the buying power utilisation of positions in an account on a PanopticPool.
    /// @param pool The PanopticPool instance to return buying power within
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return utilization The buying power utilization (= required/balance) of the account as a X10000 number
    function buyingPowerUtilization(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (uint256 utilization) {
        (, int24 tick, , , , , ) = pool.univ3pool().slot0();
        (
            uint256 balance0,
            uint256 required0,
            uint256 balance1,
            uint256 required1
        ) = checkCollateral(pool, account, tick, positionIdList);
        if (tick < 0) {
            utilization = (required0 * 10000) / balance0;
        } else {
            utilization = (required1 * 10000) / balance1;
        }
    }

    /// @notice Compute the buying power requirement of positions in an account on a PanopticPool.
    /// @param pool The PanopticPool instance to return buying power within
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return memory A two-dimensional array, consisting of one 3-item array per position, which contains:
    ///                [position balance, threshold for margin call in token0, threshold for margin call in token1]
    function buyingPowerRequirements(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (uint256[3][] memory) {
        (, int24 tick, , , , , ) = pool.univ3pool().slot0();

        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        uint256[3][] memory buyingPowerPerPosition = new uint256[3][](positionIdList.length);

        for (uint256 i; i < positionIdList.length; ++i) {
            uint256[2][] memory positionBalance = new uint256[2][](1);
            positionBalance[0] = positionBalanceArray[i];
            LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
                account,
                tick,
                positionBalance,
                shortPremium.rightSlot(),
                longPremium.rightSlot()
            );
            LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
                account,
                tick,
                positionBalance,
                shortPremium.leftSlot(),
                longPremium.leftSlot()
            );
            buyingPowerPerPosition[i][0] = positionBalance[0][0];
            buyingPowerPerPosition[i][1] = tokenData0.leftSlot();
            buyingPowerPerPosition[i][2] = tokenData1.leftSlot();
        }

        return buyingPowerPerPosition;
    }

    /// @notice Compute the buying power requirement for a position an account may take (or may already have) on a PanopticPool.
    /// @param pool The PanopticPool instance the position would be within
    /// @param account Address of the user that would take the position
    /// @param tokenId A TokenId describing the position
    /// @param positionSize The size of the position
    /// @return the threshold for margin call in token0
    /// @return the threshold for margin call in token1
    function positionBuyingPowerRequirement(
        PanopticPool pool,
        address account,
        TokenId tokenId,
        uint128 positionSize
    ) public view returns (uint128, uint128) {
        uint128 utilizations = getNewUtilizations(pool, tokenId, positionSize);

        uint256[2][] memory positionBalance = new uint256[2][](1);
        {
            positionBalance[0][0] = TokenId.unwrap(tokenId);
            positionBalance[0][1] = uint256(positionSize) + (uint256(utilizations) << 128);
        }
        {
            (, int24 tick, , , , , ) = pool.univ3pool().slot0();

            // compute single position BPR using new pool utilizations
            LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
                account,
                tick,
                positionBalance,
                0,
                0
            );
            LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
                account,
                tick,
                positionBalance,
                0,
                0
            );

            (uint256 balanceA, uint256 requiredA) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(tick)
            );

            return (tokenData0.leftSlot(), tokenData1.leftSlot());
        }
    }

    function getNewUtilizations(
        PanopticPool pool,
        TokenId tokenId,
        uint128 positionSize
    ) internal view returns (uint128 utilizations) {
        (, int24 currentTick, , , , , ) = PanopticPool(pool).univ3pool().slot0();
        int256 deltaA0;
        int256 deltaA1;
        {
            (int256 itm0, int256 itm1) = inTheMoneyAmounts(tokenId, positionSize, currentTick);
            (int256 net0, int256 net1) = getTokenFlow(tokenId, positionSize, currentTick);
            (deltaA0, deltaA1) = itm0 < 0
                ? (
                    net0 + itm0,
                    net1 + PanopticMath.convert0to1(-itm0, Math.getSqrtRatioAtTick(currentTick))
                )
                : (
                    net0 + PanopticMath.convert1to0(-itm1, Math.getSqrtRatioAtTick(currentTick)),
                    net1 + itm1
                );
        }

        (uint256 poolAssets0, uint256 insideAMM0, ) = pool.collateralToken0().getPoolData();

        (uint256 poolAssets1, uint256 insideAMM1, ) = pool.collateralToken1().getPoolData();

        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(tokenId, positionSize);
        LeftRightSigned netMoved = shortAmounts.sub(longAmounts);

        int256 moved0 = int256(netMoved.rightSlot());
        int256 moved1 = int256(netMoved.leftSlot());

        int256 newPoolUtilization0 = (10000 * (int256(insideAMM0) + moved0)) /
            (int256(poolAssets0) - deltaA0 + moved0);
        int256 newPoolUtilization1 = (10000 * (int256(insideAMM1) + moved1)) /
            (int256(poolAssets1) - deltaA1 + moved1);
        utilizations =
            uint128(uint256(newPoolUtilization0)) +
            uint128(uint256(newPoolUtilization1) << 16);
    }

    function inTheMoneyAmounts(
        TokenId tokenId,
        uint128 positionSize,
        int24 atTick
    ) public pure returns (int256, int256) {
        (int256 net0, int256 net1) = getTokenFlow(tokenId, positionSize, atTick);

        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(tokenId, positionSize);

        LeftRightSigned netMoved = shortAmounts.sub(longAmounts);

        return (int256((netMoved.rightSlot())) - net0, int256((netMoved.leftSlot())) - net1);
    }

    /// @notice Get amount of token0 and token1 that would move within a liquidity chunk if a position was minted.
    /// @param tokenId A TokenId describing the position to mint
    /// @param positionSize The size of the position
    /// @param atTick The tick between token0 and token1 on the underlying Uniswap pool
    /// @return netFlow0 How many token0s would move if the position was minted
    /// @return netFlow1 How many token1s would move if the position was minted
    function getTokenFlow(
        TokenId tokenId,
        uint128 positionSize,
        int24 atTick
    ) internal pure returns (int256 netFlow0, int256 netFlow1) {
        for (uint256 leg; leg < tokenId.countLegs(); ++leg) {
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
                netFlow0 += int256(amount0);
                netFlow1 += int256(amount1);
            } else {
                netFlow0 -= int256(amount0);
                netFlow1 -= int256(amount1);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SIZING CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    function getCoveredAmounts(
        TokenId tokenId,
        uint128 positionSize
    ) internal pure returns (int256 covered0, int256 covered1) {
        for (uint256 legIndex; legIndex < tokenId.countLegs(); ) {
            uint256 amount0;
            uint256 amount1;

            (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex);

            // effective strike price of the option (avg. price over LP range)
            // geometric mean of two numbers = √(x1 * x2) = √x1 * √x2
            uint256 geometricMeanPriceX96 = Math.mulDiv(
                Math.getSqrtRatioAtTick(tickLower),
                Math.getSqrtRatioAtTick(tickUpper),
                2 ** 96
            );

            if (tokenId.asset(legIndex) == 0) {
                amount0 = positionSize * uint128(tokenId.optionRatio(legIndex));
                amount1 = Math.mulDiv(amount0, geometricMeanPriceX96, 2 ** 96);
            } else {
                amount1 = positionSize * uint128(tokenId.optionRatio(legIndex));
                amount0 = Math.mulDiv(amount1, 2 ** 96, geometricMeanPriceX96);
            }

            if (tokenId.tokenType(legIndex) == tokenId.isLong(legIndex)) {
                // if option is a short call or a long put, add amountsMoved0 to right slot and subtract amountsMoved1 from left slot
                covered0 += int256(amount0);
                covered1 -= int256(amount1);
            } else {
                // if option is a short put or a long call, add amountsMoved1 to left slot and subtract amountsMoved0 from right slot
                covered0 -= int256(amount0);
                covered1 += int256(amount1);
            }

            unchecked {
                ++legIndex;
            }
        }
    }

    /// @notice Finds the maximum position size for a given positionIdList and a new tokenId
    /// @dev returns the max position size if the position is 1) covered or 2) naked.
    function sizePosition(
        SemiFungiblePositionManager SFPM,
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        TokenId newTokenId
    ) external view returns (uint128 coveredSize, uint128 nakedSize) {
        // get the max size for long legs: maxAvailableSize is bounded by available liquidity to purchase if there are any long legs
        uint256 maxAvailableLong = getAvailableLongSize(SFPM, pool, newTokenId);

        // get the max size from the available pool assets
        uint128 startSize = getStartSize(pool, account, newTokenId);

        // get the max size for covered minting: coveredSize is bounded by the maximum amount of tokens in the user's account to mint a covered position
        coveredSize = getCoveredSize(pool, account, newTokenId, startSize);

        // get the max size for naked minting: nakedSize is bounded by the collateral requirement of the new mint (with swapAtMint), where newCollateralRequirement = 3/4 * balance
        nakedSize = getNakedSize(pool, account, newTokenId, positionIdList, startSize);

        // scales size by: maximum amount of available liquidity for longs. Scaled coveredSize so that it's never larger than nakedSize
        nakedSize = uint128(Math.min(maxAvailableLong, nakedSize));
        coveredSize = uint128(Math.min(nakedSize, coveredSize));
    }

    /// @notice finds the absolute maximum size of the position, based on the amounts of tokens that need to be moved to Uniswap
    function getStartSize(
        PanopticPool pool,
        address account,
        TokenId newTokenId
    ) internal view returns (uint128 startSize) {
        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(newTokenId, 2 ** 64);
        LeftRightSigned netMoved = shortAmounts.sub(longAmounts);

        uint256 net0 = uint256(Math.max(netMoved.rightSlot(), 1));
        uint256 net1 = uint256(Math.max(netMoved.leftSlot(), 1));

        (uint256 balance0, , ) = pool.collateralToken0().getPoolData();
        (uint256 balance1, , ) = pool.collateralToken1().getPoolData();

        startSize = uint128(Math.min((balance0 * 2 ** 64) / net0, (balance1 * 2 ** 64) / net1));

        startSize = uint128(Math.min(startSize, 2 ** 64));
    }

    function getAvailableLongSize(
        SemiFungiblePositionManager SFPM,
        PanopticPool pool,
        TokenId newTokenId
    ) internal view returns (uint128 maxAvailableSize) {
        maxAvailableSize = type(uint128).max;
        if (newTokenId.countLongs() > 0) {
            for (uint256 i; i < newTokenId.countLegs(); ++i) {
                if (newTokenId.isLong(i) == 1) {
                    (
                        uint256 totalLiquidity,
                        uint256 netLiquidity,
                        uint256 removedLiquidity
                    ) = _getLiquidities(SFPM, pool, newTokenId, i);

                    uint256 availableLiquidity = (totalLiquidity * 9) / 10 - removedLiquidity - 1;

                    (int24 tickLower, int24 tickUpper) = newTokenId.asTicks(i);
                    if (newTokenId.asset(i) == 0) {
                        uint160 lowPriceX96 = Math.getSqrtRatioAtTick(tickLower);
                        uint160 highPriceX96 = Math.getSqrtRatioAtTick(tickUpper);
                        uint256 _max;
                        unchecked {
                            _max =
                                Math.mulDiv(
                                    uint256(availableLiquidity) << 96,
                                    highPriceX96 - lowPriceX96,
                                    highPriceX96
                                ) /
                                lowPriceX96;
                        }

                        if (_max < maxAvailableSize) {
                            maxAvailableSize = uint128(_max);
                        }
                    } else if (newTokenId.asset(i) == 1) {
                        uint160 lowPriceX96 = Math.getSqrtRatioAtTick(tickLower);
                        uint160 highPriceX96 = Math.getSqrtRatioAtTick(tickUpper);
                        uint256 _max;

                        unchecked {
                            _max = Math.mulDiv96(availableLiquidity, highPriceX96 - lowPriceX96);
                        }
                        if (_max < maxAvailableSize) {
                            maxAvailableSize = uint128(_max);
                        }
                    }
                }
            }
        }
    }

    function getCoveredSize(
        PanopticPool pool,
        address account,
        TokenId newTokenId,
        uint128 startSize
    ) internal view returns (uint128 coveredSize) {
        coveredSize = startSize;
        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) = pool.univ3pool().slot0();
        uint256 balance0 = pool.collateralToken0().convertToAssets(
            pool.collateralToken0().balanceOf(account)
        );
        uint256 balance1 = pool.collateralToken1().convertToAssets(
            pool.collateralToken1().balanceOf(account)
        );

        (int256 net0, int256 net1) = inTheMoneyAmounts(newTokenId, startSize, currentTick);

        if (net0 < 0) {
            coveredSize = uint128((balance0 * startSize) / uint256(-net0));
        } else if (net1 < 0) {
            coveredSize = uint128((balance1 * startSize) / uint256(-net1));
        }
    }

    function getNakedSize(
        PanopticPool pool,
        address account,
        TokenId newTokenId,
        TokenId[] calldata positionIdList,
        uint128 startSize
    ) internal view returns (uint128) {
        // get the max size for naked mints, ITM amounts are swapped

        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) = pool.univ3pool().slot0();

        uint256 availableCross;
        {
            (
                uint256 balance0,
                uint256 required0,
                uint256 balance1,
                uint256 required1
            ) = checkCollateral(pool, account, currentTick, positionIdList);

            uint256 balanceCross = currentTick < 0 ? balance0 : balance1;
            uint256 requiredCross = currentTick < 0 ? required0 : balance1;
            availableCross = balanceCross - (4 * requiredCross) / 3;
        }

        uint128 left = 1;
        uint128 right = startSize;

        PanopticPool _pool = pool;
        address _account = account;
        TokenId _newTokenId = newTokenId;
        int24 _currentTick = currentTick;
        uint160 _sqrtPriceX96 = sqrtPriceX96;
        while (left <= right) {
            uint128 mid = left + (right - left) / 2;
            uint128 value;

            {
                (uint128 required0, uint128 required1) = positionBuyingPowerRequirement(
                    _pool,
                    _account,
                    _newTokenId,
                    mid
                );

                int256 deltaB;
                int256 deltaR;
                (int256 itm0, int256 itm1) = inTheMoneyAmounts(_newTokenId, mid, _currentTick);

                if (_currentTick < 0) {
                    deltaR = int256(required0 + PanopticMath.convert1to0(required1, _sqrtPriceX96));
                    deltaB = itm0 + PanopticMath.convert1to0(itm1, _sqrtPriceX96);
                } else {
                    deltaR = int256(required1 + PanopticMath.convert0to1(required0, _sqrtPriceX96));
                    deltaB = itm1 + PanopticMath.convert0to1(itm0, _sqrtPriceX96);
                }
                int256 delta = ((4 * deltaR) / 3 - deltaB);
                //int256 delta = int256(availableCross * startSize) / ((4 * deltaR) / 3 - deltaB);

                value = delta > 0 ? uint128(uint256(delta)) : 0;
            }

            // Check if we found the target within tolerance
            if (
                value <= (availableCross * (10000 + 1)) / 10000 &&
                value >= (availableCross * (10000 - 1)) / 10000
            ) {
                return mid;
            }

            // If we didn't find it, continue searching
            if (value < availableCross) {
                // Prevent overflow
                if (mid == right) return mid;
                left = mid + 1;
            } else {
                // Prevent underflow
                if (mid == left) return mid;
                right = mid - 1;
            }
        }
    }

    /// @notice Query the total amount of liquidity sold in the corresponding chunk for a position leg.
    /// @dev totalLiquidity (total sold) = removedLiquidity + netLiquidity (in AMM).
    /// @param tokenId The option position
    /// @param leg The leg of the option position to get `totalLiquidity` for
    /// @return totalLiquidity The total amount of liquidity sold in the corresponding chunk for a position leg
    /// @return netLiquidity The amount of liquidity available in the corresponding chunk for a position leg
    /// @return removedLiquidity The amount of liquidity removed through buying in the corresponding chunk for a position leg
    function _getLiquidities(
        SemiFungiblePositionManager SFPM,
        PanopticPool pool,
        TokenId tokenId,
        uint256 leg
    )
        internal
        view
        returns (uint256 totalLiquidity, uint128 netLiquidity, uint128 removedLiquidity)
    {
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(leg);

        address univ3pool = address(SFPM.getUniswapV3PoolFromId(tokenId.poolId()));

        LeftRightUnsigned accountLiquidities = SFPM.getAccountLiquidity(
            univ3pool,
            address(pool),
            tokenId.tokenType(leg),
            tickLower,
            tickUpper
        );

        netLiquidity = accountLiquidities.rightSlot();
        removedLiquidity = accountLiquidities.leftSlot();

        unchecked {
            totalLiquidity = netLiquidity + removedLiquidity;
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
}
