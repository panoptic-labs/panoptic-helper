// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
// Custom types
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticHelper {
    SemiFungiblePositionManager internal immutable SFPM;

    struct Leg {
        uint64 poolId;
        address UniswapV3Pool;
        uint256 asset;
        uint256 optionRatio;
        uint256 tokenType;
        uint256 isLong;
        uint256 riskPartner;
        int24 strike;
        int24 width;
    }

    /// @notice Construct the PanopticHelper contract
    /// @param _SFPM address of the SemiFungiblePositionManager
    /// @dev the SFPM is used to get the pool ID for a given address
    constructor(SemiFungiblePositionManager _SFPM) payable {
        SFPM = _SFPM;
    }

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

        (, , uint256[2][] memory positionBalanceArray) = pool.calculateAccumulatedFeesBatch(
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


    /// @notice Fetch data about chunks in a positionIdList.
    /// @param pool The PanopticPool instance corresponding to the pool specified in `TokenId`
    /// @param account The address of the account to retrieve liquidity data for
    /// @param positionIdList List of TokenIds to evaluate
    /// @return chunkData A memory array of [positionIdList.length][4][2] containing netLiquidity and removedLiquidity for each leg
    function getChunkData(
        PanopticPool pool,
        address account,
        TokenId[] memory positionIdList
    ) external view returns (uint256[][][] memory) {
        uint256[][][] memory chunkData = new uint256[][][](positionIdList.length);

        for (uint256 i; i < positionIdList.length;) {
            uint256[][] memory ithPositionLiquidities = new uint256[][](4);

            for (uint256 j; j < positionIdList[i].countLegs();) {
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

                unchecked { ++j; }
            }

            chunkData[i] = ithPositionLiquidities;
            unchecked { ++i; }
        }

        return chunkData;
    }


    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param tokenType whether to return the values in term of token0 or token1
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance the total combined balance of token0 and token1 for a user in terms of tokenType
    /// @return requiredCollateral The combined collateral requirement for a user in terms of tokenType
    function checkCollateral(
        PanopticPool pool,
        address account,
        int24 atTick,
        uint256 tokenType,
        TokenId[] calldata positionIdList
    ) public view returns (uint256, uint256) {
        // Compute premia for all options (includes short+long premium)
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            uint256[2][] memory positionBalanceArray
        ) = pool.calculateAccumulatedFeesBatch(account, false, positionIdList);

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
        return PanopticMath.convertCollateralData(tokenData0, tokenData1, tokenType, atTick);
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

    /// @notice Evaluates if the supplied position has enough liquidity to be burnt successfully; if not, returns what the max position size would be
    /// @notice account The address of the account to evaluate
    /// @notice tokenId The TokenId to reduce the size of
    /// @notice netLiquidityUsageLimitBPS When readusting, the proportion of net liquidity to limit the new position size to using
    /// @return newTokenId The new TokenId with adjusted position size
    /// @return newPositionSize The updated size of the new position
    function reducedSizeIfNecessary(
         PanopticPool pool,
         address account,
         TokenId tokenId,
         // e.g. 90_000 to try and avoid any leg needing > 90% of the net liquidity
         uint256 netLiquidityUsageLimitBPS
    ) external view returns (TokenId newTokenId, uint128 newPositionSize) {
        // Get the details about this position's legs and current size
        Leg[] memory legs = unwrapTokenId(tokenId);

        // TODO: use new method name pool.getAccumulatedFeesAndPositionsData here eventually
        TokenId[] memory accountsPositionsToGetSizesFor = new TokenId[](1);
        accountsPositionsToGetSizesFor[0] = tokenId;
        (,,uint256[2][] memory existingPositions) = pool.calculateAccumulatedFeesBatch(
            account,
            false,
            accountsPositionsToGetSizesFor
        );
        uint128 oldPositionSize = PositionBalance.wrap(
            // The only position in the list's second item,
            // which should be the PositionBalance
            // (first item is the corresponding tokenId)
            oldPositionSizeArray[0][1]
        ).positionSize();

        newPositionSize = oldPositionSize;
        if (newTokenId.countLongs() == 0) {
            // There are no longs; sell as much as you're currently selling.
            // TODO: could be more sophisticated and return the
            // actual limit on how much you can sell for this case, even above oldPositionSize.
            return newPositionSize;
        }

        // Iterate over each leg and determine if there is enough netLiquidity in the SFPM to burn it.
        for (uint256 i = 0; i < tokenId.countLegs(); i++) {
            if (legs[i].isLong()) {
                LeftRightUnsigned liquidityData = SFPM.getAccountLiquidity(
                    legs[i].UniswapV3Pool,
                    account,
                    legs[i].tokenType,
                    legs[i].strike - (legs[i].width / 2),
                    legs[i].strike + (legs[i].width / 2)
                );
                uint256 netLiquidity = liquidityData.rightSlot();
            }

            if (newPositionSize * legs[i].optionRatio > netLiquidity) {
                // If there's not enough liquidity, adjust the new position size to keep utilization at the supplied limit
                newPositionSize = uint128((netLiquidity * netLiquidityUsageLimitBPS) / 10_000) / legs[i].optionRatio;
            }
        }
    }

    // TODO: Are these maxes correct?
    uint128 MAX_POSITION_SIZE = type(uint128).max;
    uint24 MAX_OPTION_RATIO = type(uint24).max;

    /// @notice generates a tokenID and positionSize that represents the same position as the supplied tokenID and positionSize, but with the optionRatios of each leg scaled upward/downward (and positionSize scaled inversely)
    /// @dev this is useful if you want to effectively hold the same position but need to avoid minting the same tokenID twice in a row
    /// @param oldPosition The original TokenId
    /// @param oldPositionSize The original position size
    /// @return newPosition The new TokenId with adjusted optionRatios
    /// @return newPositionSize The new position size, inversely scaled to the optionRatio changes. 0 if no valid alteration found.
    function equivalentPosition(
        TokenId oldPosition,
        uint128 oldPositionSize
    ) external pure returns(TokenId newPosition, uint128 newPositionSize) {
        Leg[] memory legs = unwrapTokenId(oldPosition);

        uint128[] optionRatios = new uint128[oldPosition.countLegs()];
        for (uint i = 0; i < oldPosition.countLegs(); i++) {
            optionRatios[i] = legs[i].optionRatio();
        }

        newPosition = oldPosition;

        // First strategy:
        // - Divide the position size by its lowest non-identity factor,
        // - and then multiply all the leg's option ratios by it
        // (if doing so results in a valid option ratio for each leg)
        bool scalingUpwardFailed = false;
        if (oldPositionSize > 1) {
            uint128 lowestOldPositionSizeFactor = _lowestNonIdentityFactor(oldPositionSize);
            for (uint i = 0; i < optionRatios.length; i++) {
                if (lowestOldPositionSizeFactor * optionRatios[i] < MAX_OPTION_RATIO) {
                    newPosition = newPosition.overwriteOptionRatio(
                        lowestOldPositionSizeFactor * optionRatios[i],
                        i
                    );
                } else {
                    scalingUpwardFailed = true;
                    break;
                }
            }

            if (!scalingUpwardFailed) {
                return (
                    newPosition,
                    oldPositionSize / lowestOldPositionSizeFactor
                );
            }
        }

        // TODO: below code can be made more concise - the ifs and return statements etc can be consolidated to still ensure we return 0 when there is no valid alteration, without this many ifs
        // Second strategy: Find the smallest non-identity common factor among the oldPosition's leg's optionRatios. if there is one:
        // - divide all of the option ratios by it
        // - return newPosition = oldPosition * LCD _if_ that value is less than max position size
        uint128 lcdAmongOptionRatios = _findLeastCommonDivisor(optionRatios);
        if (
            lcdAmongOptionRatios > 1 &&
            oldPositionSize * lcdAmongOptionRatios < MAX_POSITION_SIZE
        ) {
            for (uint i = 0; i < optionRatios.length; i++) {
                newPosition = newPosition.overwriteOptionRatio(
                    optionRatios[i] / lcdAmongOptionRatios,
                    i
                );
            }
            newPositionSize = oldPositionSize * lcdAmongOptionRatios;
        }

        // If neither of these work, return newPositionSize = 0:
    }

    function _lowestNonIdentityFactor(uint128 n) private pure returns (uint128) {
        for (uint128 i = 2; i <= n; i++)
            if (n % i == 0) return i;
    }

    function _findLeastCommonDivisor(uint128[] memory numbers) private pure returns (uint128) {
        uint128 min = numbers[0];
        for (uint i = 1; i < numbers.length; i++) {
            if (numbers[i] < min) {
                min = numbers[i];
            }
        }

        for (uint128 i = 2; i <= min; i++) {
            bool isDivisor = true;
            for (uint j = 0; j < numbers.length; j++) {
                if (numbers[j] % i != 0) {
                    isDivisor = false;
                    break;
                }
            }
            if (isDivisor) {
                return i;
            }
        }
        return 1;
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
            uint256[2][] memory positionBalance = new uint256[2][](1);

            positionBalance[0][0] = TokenId.unwrap(tokenId);
            positionBalance[0][1] = type(uint48).max;

            if (checkTokenId(tokenId, uint128(positionBalance[0][1]))) {
                LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
                    address(0xdead),
                    atTick,
                    positionBalance,
                    0,
                    0
                );
                LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
                    address(0xdead),
                    atTick,
                    positionBalance,
                    0,
                    0
                );
                (, uint256 required0) = PanopticMath.convertCollateralData(
                    tokenData0,
                    tokenData1,
                    0,
                    atTick
                );

                return required0;
            }
            return type(uint128).max;
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
            uint256 amount0;
            uint256 amount1;
            (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex);

            // effective strike price of the option (avg. price over LP range)
            // geometric mean of two numbers = √(x1 * x2) = √x1 * √x2
            uint256 geometricMeanPriceX96 = Math.mulDiv96(
                Math.getSqrtRatioAtTick(tickLower),
                Math.getSqrtRatioAtTick(tickUpper)
            );

            if (geometricMeanPriceX96 == 0) return false;

            if (tokenId.asset(legIndex) == 0) {
                amount0 = positionSize * uint128(tokenId.optionRatio(legIndex));

                amount1 = Math.mulDiv96RoundingUp(amount0, geometricMeanPriceX96);
            } else {
                amount1 = positionSize * uint128(tokenId.optionRatio(legIndex));

                amount0 = Math.mulDivRoundingUp(amount1, 2 ** 96, geometricMeanPriceX96);
            }
            if ((amount0 > type(uint120).max) || (amount1 > type(uint120).max)) {
                return false;
            }
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    // TODO: Commenting these out for now as i believe we are bumping up against size limit
    // /// @notice Returns the median of the last `cardinality` average prices over `period` observations from `univ3pool`.
    // /// @dev Used when we need a manipulation-resistant TWAP price.
    // /// @dev Uniswap observations snapshot the closing price of the last block before the first interaction of a given block.
    // /// @dev The maximum frequency of observations is 1 per block, but there is no guarantee that the pool will be observed at every block.
    // /// @dev Each period has a minimum length of blocktime * period, but may be longer if the Uniswap pool is relatively inactive.
    // /// @dev The final price used in the array (of length `cardinality`) is the average of all observations comprising `period` (which is itself a number of observations).
    // /// @dev Thus, the minimum total time window is `cardinality` * `period` * `blocktime`.
    // /// @param univ3pool The Uniswap pool to get the median observation from
    // /// @param cardinality The number of `periods` to in the median price array, should be odd.
    // /// @param period The number of observations to average to compute one entry in the median price array
    // /// @return medianTick The median of `cardinality` observations spaced by `period` in the Uniswap pool
    // function computeMedianObservedPrice(
    //     IUniswapV3Pool univ3pool,
    //     uint256 cardinality,
    //     uint256 period
    // ) external view returns (int24 medianTick) {
    //     (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

    //     (medianTick, ) = PanopticMath.computeMedianObservedPrice(
    //         univ3pool,
    //         observationIndex,
    //         observationCardinality,
    //         cardinality,
    //         period
    //     );
    // }

    // /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values.
    // /// @dev Also inserts the latest Uniswap observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    // /// @param period The minimum time in seconds that must have passed since the last observation was inserted into the buffer
    // /// @param medianData The packed structure representing the sorted 8-slot queue of ticks
    // /// @param univ3pool The Uniswap pool to retrieve observations from
    // /// @return The median of the provided 8-slot queue of ticks in `medianData`
    // /// @return The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    // function computeInternalMedian(
    //     uint256 period,
    //     uint256 medianData,
    //     IUniswapV3Pool univ3pool
    // ) external view returns (int24, uint256) {
    //     (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

    //     return
    //         PanopticMath.computeInternalMedian(
    //             observationIndex,
    //             observationCardinality,
    //             period,
    //             medianData,
    //             univ3pool
    //         );
    // }

    /// @notice Computes the twap of a Uniswap V3 pool using data from its oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window.
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages.
    /// @param univ3pool The Uniswap pool from which to compute the TWAP.
    /// @param twapWindow The time window to compute the TWAP over.
    /// @return The final calculated TWAP tick.
    function twapFilter(IUniswapV3Pool univ3pool, uint32 twapWindow) external view returns (int24) {
        return PanopticMath.twapFilter(univ3pool, twapWindow);
    }

    /// @notice Returns the net assets (balance - maintenance margin) of a given account on a given pool.
    /// @dev does not work for very large tick gradients.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param tick tick to consider
    /// @param positionIdList list of position IDs to consider
    /// @return netEquity the net assets of `account` on `pool`
    function netEquity(
        address pool,
        address account,
        int24 tick,
        TokenId[] calldata positionIdList
    ) internal view returns (int256) {
        (uint256 balanceCross, uint256 requiredCross) = checkCollateral(
            PanopticPool(pool),
            account,
            tick,
            0,
            positionIdList
        );

        return int256(balanceCross) - int256(requiredCross);
    }

    /// @notice Unwraps the contents of the tokenId into its legs.
    /// @param tokenId the input tokenId
    /// @return legs an array of leg structs
    function unwrapTokenId(TokenId tokenId) public view returns (Leg[] memory) {
        uint256 numLegs = tokenId.countLegs();
        Leg[] memory legs = new Leg[](numLegs);

        uint64 poolId = tokenId.poolId();
        address UniswapV3Pool = address(SFPM.getUniswapV3PoolFromId(tokenId.poolId()));
        for (uint256 i = 0; i < numLegs; ++i) {
            legs[i].poolId = poolId;
            legs[i].UniswapV3Pool = UniswapV3Pool;
            legs[i].asset = tokenId.asset(i);
            legs[i].optionRatio = tokenId.optionRatio(i);
            legs[i].tokenType = tokenId.tokenType(i);
            legs[i].isLong = tokenId.isLong(i);
            legs[i].riskPartner = tokenId.riskPartner(i);
            legs[i].strike = tokenId.strike(i);
            legs[i].width = tokenId.width(i);
        }
        return legs;
    }

    /// @notice Returns an estimate of the downside liquidation price for a given account on a given pool.
    /// @dev returns MIN_TICK if the LP is more than 100000 ticks below the current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the downward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceDown(
        address pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        (, int24 currentTick, , , , , ) = PanopticPool(pool).univ3pool().slot0();
        int24 x0 = currentTick - 10000;
        int24 x1 = currentTick;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is below currentTick - tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, return MIN_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MIN_V3POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice Returns an estimate of the upside liquidation price for a given account on a given pool.
    /// @dev returns MAX_TICK if the LP is more than 100000 ticks above current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the upward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceUp(
        address pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        (, int24 currentTick, , , , , ) = PanopticPool(pool).univ3pool().slot0();
        int24 x0 = currentTick;
        int24 x1 = currentTick + 10000;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is within the range of currentTick +- tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the corresponding max/min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, stop + return MAX_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MAX_V3POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice initializes a given leg in a tokenId as a call.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addCallLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return
            TokenIdLibrary.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                0,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice initializes a given leg in a tokenId as a put.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addPutLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return
            TokenIdLibrary.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                1,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice creates "Classic" strangle using a call and a put, with asymmetric upward risk.
    /// @dev example: createStrangle(uniPoolAddress, 4, 50, -50, 0, 1, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the strangle
    /// @param callStrike strike of the call
    /// @param putStrike strike of the put
    /// @param asset asset of the strangle
    /// @param isLong is the strangle long or short
    /// @param optionRatio relative size of the strangle
    /// @param start leg index where the (2 legs) of the strangle begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createStrangle(
        address univ3pool,
        int24 width,
        int24 callStrike,
        int24 putStrike,
        uint256 asset,
        uint256 isLong,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // A strangle is composed of
        // 1. a call with a higher strike price
        // 2. a put with a lower strike price

        // Call w/ higher strike
        tokenId = addCallLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            isLong,
            start + 1,
            callStrike,
            width
        );

        // Put w/ lower strike
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            isLong,
            start,
            putStrike,
            width
        );
    }

    /// @notice creates "Classic" straddle using a call and a put, with asymmetric upward risk.
    /// @dev createStraddle(uniPoolAddress, 4, 0, 0, 1, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the strangle
    /// @param strike strike of the call and put
    /// @param asset asset of the strangle
    /// @param isLong is the strangle long or short
    /// @param optionRatio relative size of the strangle
    /// @param start leg index where the (2 legs) of the straddle begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createStraddle(
        address univ3pool,
        int24 width,
        int24 strike,
        uint256 asset,
        uint256 isLong,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // A straddle is composed of
        // 1. a call with an identical strike price
        // 2. a put with an identical strike price

        // call
        tokenId = addCallLeg(tokenId, start, optionRatio, asset, isLong, start + 1, strike, width);

        // put
        tokenId = addPutLeg(tokenId, start + 1, optionRatio, asset, isLong, start, strike, width);
    }

    /// @notice creates a call spread with 1 long leg and 1 short leg.
    /// @dev example: createCallSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallSpread(
        address univ3pool,
        int24 width,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // A call spread is composed of
        // 1. a long call with a lower strike price
        // 2. a short call with a higher strike price

        // Long call
        tokenId = addCallLeg(tokenId, start, optionRatio, asset, 1, start + 1, strikeLong, width);

        // Short call
        tokenId = addCallLeg(tokenId, start + 1, optionRatio, asset, 0, start, strikeShort, width);
    }

    /// @notice creates a put spread with 1 long leg and 1 short leg.
    /// @dev example: createPutSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutSpread(
        address univ3pool,
        int24 width,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // A put spread is composed of
        // 1. a long put with a higher strike price
        // 2. a short put with a lower strike price

        // Long put
        tokenId = addPutLeg(tokenId, start, optionRatio, asset, 1, start + 1, strikeLong, width);

        // Short put
        tokenId = addPutLeg(tokenId, start + 1, optionRatio, asset, 0, start, strikeShort, width);
    }

    /// @notice creates a diagonal spread with 1 long leg and 1 short leg.abi.
    /// @dev example: createCallDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallDiagonalSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // A call diagonal spread is composed of
        // 1. a long call with a (lower/higher) strike price and (lower/higher) width(expiry)
        // 2. a short call with a (higher/lower) strike price and (higher/lower) width(expiry)

        // Long call
        tokenId = addCallLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            1,
            start + 1,
            strikeLong,
            widthLong
        );

        // Short call
        tokenId = addCallLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            0,
            start,
            strikeShort,
            widthShort
        );
    }

    /// @notice creates a diagonal spread with 1 long leg and 1 short leg.
    /// @dev example: createPutDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutDiagonalSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // A bearish diagonal spread is composed of
        // 1. a long put with a (higher/lower) strike price and (lower/higher) width(expiry)
        // 2. a short put with a (lower/higher) strike price and (higher/lower) width(expiry)

        // Long put
        tokenId = addPutLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            1,
            start + 1,
            strikeLong,
            widthLong
        );

        // Short put
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            0,
            start,
            strikeShort,
            widthShort
        );
    }

    /// @notice creates a calendar spread with 1 long leg and 1 short leg.
    /// @dev example: createCallCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strike strike of the long and short legs
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallCalendarSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strike,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // calendar spread is a diagonal spread where the legs have identical strike prices
        // so we can create one using the diagonal spread function
        tokenId = createCallDiagonalSpread(
            univ3pool,
            widthLong,
            widthShort,
            strike,
            strike,
            asset,
            optionRatio,
            start
        );
    }

    /// @notice creates a calendar spread with 1 long leg and 1 short leg.
    /// @dev example: createPutCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strike strike of the long and short legs
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutCalendarSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strike,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // calendar spread is a diagonal spread where the legs have identical strike prices
        // so we can create one using the diagonal spread function
        tokenId = createPutDiagonalSpread(
            univ3pool,
            widthLong,
            widthShort,
            strike,
            strike,
            asset,
            optionRatio,
            start
        );
    }

    /// @notice creates iron condor w/ call and put spread.
    /// @dev example: createIronCondor(uniPoolAddress, 4, 50, -50, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param callStrike strike of the call spread
    /// @param putStrike strike of the put spread
    /// @param wingWidth width of the wings
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createIronCondor(
        address univ3pool,
        int24 width,
        int24 callStrike,
        int24 putStrike,
        int24 wingWidth,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // an iron condor is composed of
        // 1. a call spread
        // 2. a put spread
        // the "wings" represent how much more OTM the long sides of the spreads are

        // call spread
        tokenId = createCallSpread(
            univ3pool,
            width,
            callStrike + wingWidth,
            callStrike,
            asset,
            1,
            0
        );

        // put spread
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutSpread(
                        address(0),
                        width,
                        putStrike - wingWidth,
                        putStrike,
                        asset,
                        1,
                        2
                    )
                )
        );
    }

    /// @notice creates a jade lizard w/ long call and short asymmetric (traditional) strangle.
    /// @dev example: createJadeLizard(uniPoolAddress, 4, 100, 50, -50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param shortCallStrike strike of the short call
    /// @param shortPutStrike strike of the short put
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createJadeLizard(
        address univ3pool,
        int24 width,
        int24 longCallStrike,
        int24 shortCallStrike,
        int24 shortPutStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a jade lizard is composed of
        // 1. a short strangle
        // 2. a long call

        // short strangle
        tokenId = createStrangle(univ3pool, width, shortCallStrike, shortPutStrike, asset, 0, 1, 1);

        // long call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 1, 0, longCallStrike, width);
    }

    /// @notice creates a big lizard w/ long call and short asymmetric (traditional) straddle.
    /// @dev example: createBigLizard(uniPoolAddress, 4, 100, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param straddleStrike strike of the short straddle
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createBigLizard(
        address univ3pool,
        int24 width,
        int24 longCallStrike,
        int24 straddleStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a big lizard is composed of
        // 1. a short straddle
        // 2. a long call

        // short straddle
        tokenId = createStraddle(univ3pool, width, straddleStrike, asset, 0, 1, 1);

        // long call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 1, 0, longCallStrike, width);
    }

    /// @notice creates a super bull w/ long call spread and short put.
    /// @dev example: createSuperBull(uniPoolAddress, 4, -50, 50, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param shortCallStrike strike of the short call
    /// @param shortPutStrike strike of the short put
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createSuperBull(
        address univ3pool,
        int24 width,
        int24 longCallStrike,
        int24 shortCallStrike,
        int24 shortPutStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a super bull is composed of
        // 1. a long call spread
        // 2. a short put

        // long call spread
        tokenId = createCallSpread(univ3pool, width, longCallStrike, shortCallStrike, asset, 1, 1);

        // short put
        tokenId = addPutLeg(tokenId, 0, 1, asset, 0, 0, shortPutStrike, width);
    }

    /// @notice creates a super bear w/ long put spread and short call.
    /// @dev example: createSuperBear(uniPoolAddress, 4, 50, -50, -50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longPutStrike strike of the long put
    /// @param shortPutStrike strike of the short put
    /// @param shortCallStrike strike of the short call
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createSuperBear(
        address univ3pool,
        int24 width,
        int24 longPutStrike,
        int24 shortPutStrike,
        int24 shortCallStrike,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // a super bear is composed of
        // 1. a long put spread
        // 2. a short call

        // long put spread
        tokenId = createPutSpread(univ3pool, width, longPutStrike, shortPutStrike, asset, 1, 1);

        // short call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 0, 0, shortCallStrike, width);
    }

    /// @notice creates a butterfly w/ long call spread and short put spread.
    /// @dev example: createIronButterfly(uniPoolAddress, 4, 0, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param strike strike of the long and short legs
    /// @param wingWidth width of the wings
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createIronButterfly(
        address univ3pool,
        int24 width,
        int24 strike,
        int24 wingWidth,
        uint256 asset
    ) public view returns (TokenId tokenId) {
        // an iron butterfly is composed of
        // 1. a long call spread
        // 2. a short put spread

        // long call spread
        tokenId = createCallSpread(univ3pool, width, strike, strike + wingWidth, asset, 1, 0);

        // short put spread
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutSpread(address(0), width, strike, strike - wingWidth, asset, 1, 2)
                )
        );
    }

    /// @notice creates a ratio spread w/ long call and multiple short calls.
    /// @dev example: createCallRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long call
    /// @param shortStrike strike of the short calls
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short calls to the long call
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured

    function createCallRatioSpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // a call ratio spread is composed of
        // 1. a long call
        // 2. multiple short calls

        // long call
        tokenId = addCallLeg(tokenId, start, 1, asset, 1, start + 1, longStrike, width);

        // short calls
        tokenId = addCallLeg(tokenId, start + 1, ratio, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ratio spread w/ long put and multiple short puts.
    /// @dev example: createPutRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long put
    /// @param shortStrike strike of the short puts
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short puts to the long put
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutRatioSpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // a put ratio spread is composed of
        // 1. a long put
        // 2. multiple short puts

        // long put
        tokenId = addPutLeg(tokenId, start, 1, asset, 1, start + 1, longStrike, width);

        // short puts
        tokenId = addPutLeg(tokenId, start + 1, ratio, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEBRA spread w/ short call and multiple long calls.
    /// @dev example: createCallZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long calls
    /// @param shortStrike strike of the short call
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short call to the long calls
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallZEBRASpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // a call ZEBRA(zero extrinsic value back ratio spread) spread is composed of
        // 1. a short call
        // 2. multiple long calls

        // long put
        tokenId = addCallLeg(tokenId, start, ratio, asset, 1, start + 1, longStrike, width);

        // short puts
        tokenId = addCallLeg(tokenId, start + 1, 1, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEBRA spread w/ short put and multiple long puts.
    /// @dev example: createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long puts
    /// @param shortStrike strike of the short put
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short put to the long puts
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutZEBRASpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (TokenId tokenId) {
        // Pool
        tokenId = tokenId.addPoolId(SFPM.getPoolId(univ3pool));

        // a put ZEBRA(zero extrinsic value back ratio spread) spread is composed of
        // 1. a short put
        // 2. multiple long puts

        // long puts
        tokenId = addPutLeg(tokenId, start, ratio, asset, 1, start + 1, longStrike, width);

        // short put
        tokenId = addPutLeg(tokenId, start + 1, 1, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEEHBS w/ call and put ZEBRA spreads.
    /// @dev example: createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long legs
    /// @param shortStrike strike of the short legs
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short legs to the long legs
    /// @return tokenId the position id with the strategy configured
    function createZEEHBS(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio
    ) public view returns (TokenId tokenId) {
        // a ZEEHBS(Zero extrinsic hedged back spread) is composed of
        // 1. a call ZEBRA spread
        // 2. a put ZEBRA spread

        // call ZEBRA
        tokenId = createCallZEBRASpread(univ3pool, width, longStrike, shortStrike, asset, ratio, 0);

        // put ZEBRA
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutZEBRASpread(
                        address(0),
                        width,
                        longStrike,
                        shortStrike,
                        asset,
                        ratio,
                        2
                    )
                )
        );
    }

    /// @notice creates a BATS (AKA double ratio spread) w/ call and put ratio spreads.
    /// @dev example: createBATS(uniPoolAddress, 4, -50, 50, 0, 2).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long legs
    /// @param shortStrike strike of the short legs
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short legs to the long legs
    /// @return tokenId the position id with the strategy configured
    function createBATS(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio
    ) public view returns (TokenId tokenId) {
        // a BATS(double ratio spread) is composed of
        // 1. a call ratio spread
        // 2. a put ratio spread

        // call ratio spread
        tokenId = createCallRatioSpread(univ3pool, width, longStrike, shortStrike, asset, ratio, 0);

        // put ratio spread
        tokenId = TokenId.wrap(
            TokenId.unwrap(tokenId) +
                TokenId.unwrap(
                    createPutRatioSpread(
                        address(0),
                        width,
                        longStrike,
                        shortStrike,
                        asset,
                        ratio,
                        2
                    )
                )
        );
    }

    // sizeThePosition: given a list of active positions, a prospective position, and a target buying power percentage:
    // tell me what # of contracts to do the prospective position at such that my post-mint buying power is the target

    // how?

    // step 1: figure out the total buying power this user has based on their current collateral value
    // (e.g., reciprocal of our margin requirement * collateralValue - i think that'd be 5*collateralValue
    // step 2: multiply (1) by targetBuyingPowerPercentageUsage / 100 to figure out the total buyingPowerUsage their account can handle
    // step 3: figure out the buyingPower the prospective position would use up for 1 contract
    // - This differs on a few things:
    // -- Buying and selling have different margin requirements:
    /*

    /// @notice Required collateral ratios for buying, represented as percentage * 10_000.
    /// @dev i.e 20% -> 0.2 * 10_000 = 2_000.
    uint256 immutable SELLER_COLLATERAL_RATIO;

    /// @notice Required collateral ratios for selling, represented as percentage * 10_000.
    /// @dev i.e 10% -> 0.1 * 10_000 = 1_000.
    uint256 immutable BUYER_COLLATERAL_RATIO;
    */
    // -- And risk-partnered positions have more generous margin requirements too


    // step 4: Find a number of contracts x that uses up (2) - x*(3):

    // - the upper bound of this value is what you'd expect: ((2) - (3)) / x
    // - however, executing a mint will:
    // -- affect token prices
    // -- may increase/decrease pool utilisation which changes the margin requirement

    // Random notes from talking with Henry Wed Oct 16th:
    // step 1: figure out how  current collateral amount and notional value
    //  what multiplier of collateral
    // (e.g., the reverse of the collateral requirement formula in CollateralTracker.getAccountMarginDetails)
    // this gives you some multiplier which is the largest possible position size
    // you then attempt a mint and see what impact on pool utilisation is
    // - if it pushes PU too high you try again with lower value
    // then, get your average you also take your average execution cost
    /*uint256 constant DECIMALS = 10_000;

    function sizeThePosition(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        uint256 percentBPR
    ) external view returns (uint128 positionSize) {
        // Constraint 1: The new position's size should be capped such that positionSize * requiredForPosition <= currentCrossBalance - currentPositionRequired
        uint128 requiredForPosition = _requiredCollateralForSinglePosition(
            pool,
            _getCurrentTick(pool),
            0,
            account,
            positionIdList[positionIdList.length - 1]
        );
        uint128 boundForCurrentExcessBuyingPower = _excessBuyingPower(pool, account, positionIdList) / requiredForPosition;

        // Constraint 2: Long legs can only buy up all liquidity at their strike price

        // Constraint 3: Pool utilisation cannot exceed 90%

        // TODO: Return the min of all calculated position sizes for the various constraints to consider
        return Math.min(
            Math.min(
                boundForCurrentExcessBuyingPower,
                type(uint128).max
            ),
            Math.min(
                type(uint128).max,
                type(uint128).max
            )
        );
    }

    // TODO: might just be able to use checkCollateral and pass in a single positionId for this?
    function _requiredCollateralForSinglePosition(
        PanopticPool pool,
        int24 atTick,
        uint256 tokenType,
        address account,
        TokenId position
    ) internal view returns(uint128) {
        // Query the current and required collateral amounts for the two tokens
        LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
            account,
            atTick,
            [position],
            0,
            0
        );
        LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
            account,
            atTick,
            [position],
            0,
            0
        );

        // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
        return PanopticMath.convertCollateralData(tokenData0, tokenData1, tokenType, atTick);
    }

    // TODO this is the same as netEquity
    function _excessBuyingPower(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList
    ) internal view returns(uint128 excessCollateral) {
        (uint256 collateralBalance, uint256 requiredCollateral) = checkCollateral(pool, account, _getCurrentTick(pool), 0, positionIdList);

        if (collateralBalance <= requiredCollateral) {
            return 0;
        }
        excessCollateral = collateralBalance - requiredCollateral;

    }

    function _getCurrentTick(PanopticPool pool) internal view returns (int24) {
        (, int24 currentTick, , , , , ) = pool.univ3pool().slot0();
        return currentTick;
    }

    /*Stashing boilerplate:
    function sizeThePosition(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        uint256 percentBPR
    ) external view returns (uint128 positionSize) {
        TokenId newTokenId = positionIdList[positionIdList.length - 1];

        // Step 1: Calculate total buying power based on current collateral and pool utilization
        CollateralTracker ct0 = pool.collateralToken0();
        CollateralTracker ct1 = pool.collateralToken1();
        (uint256 poolAssets0, uint256 inAMM0, uint256 utilization0) = ct0.getPoolData();
        (uint256 poolAssets1, uint256 inAMM1, uint256 utilization1) = ct1.getPoolData();

        uint256 collateral0 = ct0.convertToAssets(ct0.balanceOf(account));
        uint256 collateral1 = ct1.convertToAssets(ct1.balanceOf(account));

        uint256 totalBuyingPower = calculateTotalBuyingPower(
            collateral0,
            collateral1,
            utilization0,
            utilization1,
            ct0,
            ct1
        );

        // Step 2: Calculate target buying power usage
        uint256 targetBuyingPowerUsage = (totalBuyingPower * percentBPR) / DECIMALS;

        // Get current pool data
        (int24 currentTick, int24 fastOracleTick, , , ) = pool.getOracleTicks();

        // Step 3-4: Binary search for optimal position size
        uint128 low = 1;
        uint128 high = type(uint128).max;
        uint128 mid;

        while (low <= high) {
            mid = low + (high - low) / 2;

            // Simulate position with current mid size
            (uint256 bpUsed, int256 swapAmount0, int256 swapAmount1) = simulatePosition(
                pool,
                account,
                positionIdList,
                newTokenId,
                mid,
                currentTick,
                fastOracleTick,
                utilization0,
                utilization1
            );

            if (bpUsed == targetBuyingPowerUsage) {
                return mid;
            } else if (bpUsed < targetBuyingPowerUsage) {
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }

        // Final check with different utilization scenarios
        uint256 swapExecutionPrice = calculateSwapExecutionPrice(currentTick, swapAmount0, swapAmount1);
        uint256 newUtil0 = calculateNewUtilization(poolAssets0, inAMM0, swapAmount0);
        uint256 newUtil1 = calculateNewUtilization(poolAssets1, inAMM1, swapAmount1);

        uint128 size1 = calculateSizeForTarget(pool, account, positionIdList, newTokenId, targetBuyingPowerUsage, fastOracleTick, currentTick, swapExecutionPrice, utilization0, utilization1, false);
        uint128 size2 = calculateSizeForTarget(pool, account, positionIdList, newTokenId, targetBuyingPowerUsage, fastOracleTick, currentTick, swapExecutionPrice, newUtil0, utilization1, false);
        uint128 size3 = calculateSizeForTarget(pool, account, positionIdList, newTokenId, targetBuyingPowerUsage, fastOracleTick, currentTick, swapExecutionPrice, utilization0, newUtil1, false);
        uint128 size4 = calculateSizeForTarget(pool, account, positionIdList, newTokenId, targetBuyingPowerUsage, fastOracleTick, currentTick, swapExecutionPrice, newUtil0, newUtil1, false);

        return Math.min(Math.min(size1, size2), Math.min(size3, size4));
    }

    function calculateTotalBuyingPower(
        uint256 collateral0,
        uint256 collateral1,
        uint256 utilization0,
        uint256 utilization1,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) internal view returns (uint256) {
        uint256 buyingPower0 = (collateral0 * DECIMALS) / ct0.SELLER_COLLATERAL_RATIO();
        uint256 buyingPower1 = (collateral1 * DECIMALS) / ct1.SELLER_COLLATERAL_RATIO();

        // Adjust buying power based on utilization
        buyingPower0 = (buyingPower0 * DECIMALS) / ct0._sellCollateralRatio(int256(utilization0));
        buyingPower1 = (buyingPower1 * DECIMALS) / ct1._sellCollateralRatio(int256(utilization1));

        return buyingPower0 + buyingPower1;
    }

    function simulatePosition(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        TokenId newTokenId,
        uint128 positionSize,
        int24 currentTick,
        int24 fastOracleTick,
        uint256 utilization0,
        uint256 utilization1
    ) internal view returns (uint256 buyingPowerUsed, int256 swapAmount0, int256 swapAmount1) {
        // Simulate minting the position and calculate buying power used
        (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) = pool.SFPM().mintTokenizedPosition(newTokenId, positionSize, type(int24).min, type(int24).max);

        swapAmount0 = totalSwapped.rightSlot();
        swapAmount1 = totalSwapped.leftSlot();

        // Calculate buying power used based on position requirements
        buyingPowerUsed = calculateBuyingPowerUsed(pool, account, positionIdList, newTokenId, positionSize, currentTick, fastOracleTick, utilization0, utilization1);
    }

    function calculateBuyingPowerUsed(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        TokenId newTokenId,
        uint128 positionSize,
        int24 currentTick,
        int24 fastOracleTick,
        uint256 utilization0,
        uint256 utilization1
    ) internal view returns (uint256) {
        CollateralTracker ct0 = pool.collateralToken0();
        CollateralTracker ct1 = pool.collateralToken1();

        uint256 requiredCollateral0 = 0;
        uint256 requiredCollateral1 = 0;

        // Calculate required collateral for existing positions
        for (uint256 i = 0; i < positionIdList.length; i++) {
            (uint256 required0, uint256 required1) = calculateRequiredCollateral(
                pool,
                positionIdList[i],
                currentTick,
                utilization0,
                utilization1
            );
            requiredCollateral0 += required0;
            requiredCollateral1 += required1;
        }

        // Calculate required collateral for the new position
        (uint256 newRequired0, uint256 newRequired1) = calculateRequiredCollateral(
            pool,
            newTokenId,
            currentTick,
            utilization0,
            utilization1
        );
        requiredCollateral0 += newRequired0;
        requiredCollateral1 += newRequired1;

        // Convert required collateral to buying power used
        uint256 buyingPowerUsed0 = (requiredCollateral0 * DECIMALS) / ct0.SELLER_COLLATERAL_RATIO();
        uint256 buyingPowerUsed1 = (requiredCollateral1 * DECIMALS) / ct1.SELLER_COLLATERAL_RATIO();

        return buyingPowerUsed0 + buyingPowerUsed1;
    }

    function calculateRequiredCollateral(
        PanopticPool pool,
        TokenId tokenId,
        int24 currentTick,
        uint256 utilization0,
        uint256 utilization1
    ) internal view returns (uint256 required0, uint256 required1) {
        // Implement the logic to calculate required collateral for a single position
        // This should use the CollateralTracker's _getRequiredCollateralAtTickSinglePosition function
        // and account for both token0 and token1 collateral requirements
        // Placeholder implementation
        return (0, 0);
    }

    function calculateSwapExecutionPrice(int24 currentTick, int256 swapAmount0, int256 swapAmount1) internal pure returns (uint256) {
        // Implement swap execution price calculation based on amounts and current tick
        // This is a placeholder implementation
        return uint256(uint24(currentTick));
    }

    function calculateNewUtilization(uint256 poolAssets, uint256 inAMM, int256 swapAmount) internal pure returns (uint256) {
        // Calculate new utilization based on pool assets, current in-AMM amount, and swap amount
        return ((inAMM + uint256(swapAmount > 0 ? swapAmount : 0)) * DECIMALS) / (poolAssets + inAMM);
    }

    function calculateSizeForTarget(
        PanopticPool pool,
        address account,
        TokenId[] calldata positionIdList,
        TokenId newTokenId,
        uint256 targetBuyingPowerUsage,
        int24 fastOracleTick,
        int24 currentTick,
        uint256 swapExecutionPrice,
        uint256 utilization0,
        uint256 utilization1,
        bool useMinCR
    ) internal view returns (uint128) {
        // Implement the logic to calculate position size based on target buying power usage
        // This should use the provided parameters to determine the optimal size
        // Placeholder implementation
        return type(uint128).max;
    }
    */



}
