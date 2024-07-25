// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;
import "forge-std/Test.sol";

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

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticHelper {
    SemiFungiblePositionManager internal immutable SFPM;

    using Strings for uint256;

    // Constants for chart dimensions
    int256 private constant WIDTH = 500;
    int256 private constant HEIGHT = 300;
    int256 private constant PADDING = 40;

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
        (int128 premium0, int128 premium1, uint256[2][] memory positionBalanceArray) = pool
            .calculateAccumulatedFeesBatch(account, false, positionIdList);

        // Query the current and required collateral amounts for the two tokens
        LeftRightUnsigned tokenData0 = pool.collateralToken0().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium0
        );
        LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium1
        );

        // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
        return PanopticMath.convertCollateralData(tokenData0, tokenData1, tokenType, atTick);
    }

    /// @notice optimizes the risk partneting of all legs within a tokenId
    /// @param pool The PanopticPool instance to optimize the tokenId for
    /// @param atTick At what price is the collateral requirement evaluated at
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

    /// @notice An external function that returns the collateral needed for a single tokenId at the provided tick
    /// @param pool The PanopticPool instance to optimize the tokenId for
    /// @param atTick At what price is the collateral requirement evaluated at
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
                    0
                );
                LeftRightUnsigned tokenData1 = pool.collateralToken1().getAccountMarginDetails(
                    address(0xdead),
                    atTick,
                    positionBalance,
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

    /// @notice an external function that validates a tokenId
    /// @param self the tokenId to be tested
    function validateTokenId(TokenId self) external pure returns (bool) {
        self.validate();
        for (uint256 leg; leg < self.countLegs(); ++leg) {
            (int24 tickLower, int24 tickUpper) = self.asTicks(leg);
        }
    }

    /// @notice an external function that ensures that the proposed tokenId can be minted
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
    /// @return The median of `cardinality` observations spaced by `period` in the Uniswap pool
    function computeMedianObservedPrice(
        IUniswapV3Pool univ3pool,
        uint256 cardinality,
        uint256 period
    ) external view returns (int24) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

        return
            PanopticMath.computeMedianObservedPrice(
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

    function getTickNets(
        IUniswapV3Pool univ3pool
    ) external view returns (int256[] memory, int256[] memory) {
        (, int24 currentTick, , , , , ) = univ3pool.slot0();
        int24 tickSpacing = univ3pool.tickSpacing();
        int256 scaledTick = int256((currentTick / tickSpacing) * tickSpacing);

        int256[] memory tickData = new int256[](201);
        int256[] memory liquidityNets = new int256[](201);

        uint256 i;
        for (int256 dt = -100; dt < 100; ) {
            (, int128 liquidityNet, , , , , , ) = univ3pool.ticks(
                int24(scaledTick + dt * tickSpacing)
            );

            if (i == 0) {
                tickData[i] = scaledTick + dt * tickSpacing;
                liquidityNets[i] = 250220217232024050;
            }
            tickData[i + 1] = scaledTick + dt * tickSpacing;
            liquidityNets[i + 1] = liquidityNets[i] + liquidityNet;

            //console2.log(tickData[i + 1]);
            //console2.log(liquidityNets[i+1]);
            ++i;
            ++dt;
        }

        return (tickData, liquidityNets);
    }

    function toStringSignedPct(int256 value) public pure returns (string memory) {
        if (value < 0) {
            return
                string(
                    abi.encodePacked(
                        "-",
                        uint256(-value / 100).toString(),
                        ".",
                        ((-value % 100) < 10) ? '0' : '',
                        uint256(-value % 100).toString() 
                    )
                );
        } else {
            return
                string(
                    abi.encodePacked(
                        uint256(value / 100).toString(),
                        ".",
                        ((value % 100) < 10) ? '0' : '',
                        uint256(value % 100).toString()
                    )
                );
        }
    }

    function toStringSigned(int256 value) internal pure returns (string memory) {
        if (value < 0) {
            return string(abi.encodePacked("-", uint256(-value).toString()));
        } else {
            return uint256(value).toString();
        }
    }

    function generateSVGChart(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int256 currentTick,
        uint256 chartType
    ) public pure returns (string memory) {
        require(tickData.length == liquidityData.length, "Data length mismatch");
        require(tickData.length > 1, "Not enough data points");

        (int256 minTick, int256 maxTick, int256 minLiquidity, int256 maxLiquidity) = findMinMax(
            tickData,
            liquidityData
        );

        string memory svgStart = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="',
                uint256(WIDTH).toString(),
                '" height="',
                uint256(HEIGHT).toString(),
                '">',
                '<rect width="100%" height="100%" fill="white"/><defs><linearGradient id="lineGradient" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" style="stop-color:rgba(91,12,214,0.75)"/><stop offset="100%" style="stop-color:rgba(91,12,214,0)"/></linearGradient><linearGradient id="barGradient" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" style="stop-color:rgba(91,12,214,0.75)"/><stop offset="100%" style="stop-color:rgba(91,12,214,0.25)"/></linearGradient></defs>'
            )
        );

        string memory chartData;
        if (chartType == 0) {
            chartData = generateLineChart(
                tickData,
                liquidityData,
                minTick,
                maxTick,
                minLiquidity,
                maxLiquidity
            );
        } else {
            chartData = generateBarChart(
                tickData,
                liquidityData,
                currentTick,
                minTick,
                maxTick,
                minLiquidity,
                maxLiquidity
            );
        }

        string memory axes = generateAxes(
            tickData,
            currentTick,
            minTick,
            maxTick,
            minLiquidity,
            maxLiquidity
        );

        string memory svgEnd = "</svg>";

        return string(abi.encodePacked(svgStart, chartData, axes, svgEnd));
    }

    function generateLineChart(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int256 minTick,
        int256 maxTick,
        int256 minLiquidity,
        int256 maxLiquidity
    ) private pure returns (string memory) {
        string memory pathData = "M";
        string memory circles = "";

        minLiquidity = minLiquidity / 2;
        maxLiquidity = (maxLiquidity * 11) / 10;
        minTick = minTick - (tickData[1] - tickData[0]);
        maxTick = maxTick + (tickData[1] - tickData[0]);

        for (uint i = 0; i < tickData.length; i++) {
            int256 x = ((tickData[i] - minTick) * (WIDTH - 2 * PADDING)) /
                (maxTick - minTick) +
                PADDING;
            int256 y = HEIGHT -
                (((liquidityData[i] - minLiquidity) * (HEIGHT - 2 * PADDING)) /
                    (maxLiquidity - minLiquidity) +
                    PADDING);

            pathData = string(
                abi.encodePacked(
                    pathData,
                    i == 0 ? "" : " L",
                    toStringSigned(x),
                    ",",
                    toStringSigned(y)
                )
            );

            circles = string(
                abi.encodePacked(
                    circles,
                    '<circle cx="',
                    toStringSigned(x),
                    '" cy="',
                    toStringSigned(y),
                    '" r="3" fill="black" />'
                )
            );
        }

        pathData = string(
            abi.encodePacked(
                pathData,
                " L",
                uint256(WIDTH - PADDING).toString(),
                ",",
                uint256(HEIGHT - PADDING).toString(),
                " L",
                uint256(PADDING).toString(),
                ",",
                uint256(HEIGHT - PADDING).toString(),
                " Z"
            )
        );

        return
            string(
                abi.encodePacked(
                    '<path d="',
                    pathData,
                    '" fill="url(#lineGradient)" stroke="rgba(91,12,241,1)" stroke-width="2"/>',
                    circles
                )
            );
    }

    function generateBarChart(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int256 currentTick,
        int256 minTick,
        int256 maxTick,
        int256 minLiquidity,
        int256 maxLiquidity
    ) private pure returns (string memory) {
        string memory bars = "";
        int256 barWidth = (((100 * (WIDTH - 2 * PADDING)) / int256(tickData.length + 1)) * 92) / 100; // fill available width, just about

        minLiquidity = minLiquidity / 2;
        maxLiquidity = (maxLiquidity * 11) / 10;

        minTick = minTick - (tickData[1] - tickData[0]);
        maxTick = maxTick + (tickData[1] - tickData[0]);

        for (uint i = 0; i < tickData.length; i++) {
            int256 x = (100 * (tickData[i] - minTick) * (WIDTH - 2 * PADDING)) /
                (maxTick - minTick) +
                100 * PADDING;
            int256 y = HEIGHT -
                (((liquidityData[i] - minLiquidity) * (HEIGHT - 2 * PADDING)) /
                    (maxLiquidity - minLiquidity) +
                    PADDING);
            int256 barHeight = HEIGHT - y - PADDING;

            bars = string(
                abi.encodePacked(
                    bars,
                    '<rect x="',
                    toStringSignedPct(x - (barWidth) / 2),
                    '" y="',
                    toStringSignedPct(100*y),
                    '" width="',
                    toStringSignedPct(barWidth),
                    '" height="',
                    toStringSignedPct(100 * barHeight),
                    '" fill="url(#barGradient)" stroke="white" stroke-width="0.25" />'
                )
            );
        }

        {
            int256 currentTickX = ((currentTick - minTick) * (WIDTH - 2 * PADDING)) /
                (maxTick - minTick) +
                PADDING;
            // Add the vertical line for the current tick
            string memory currentTickLine = string(
                abi.encodePacked(
                    '<line x1="',
                    uint256(currentTickX).toString(),
                    '" y1="',
                    uint256(PADDING).toString(),
                    '" x2="',
                    uint256(currentTickX).toString(),
                    '" y2="',
                    uint256(HEIGHT - PADDING).toString(),
                    '" stroke="deeppink" stroke-width="2" />'
                )
            );

            bars = string(abi.encodePacked(bars, currentTickLine));
        }
        return bars;
    }

    function generateAxes(
        int256[] memory tickData,
        int256 currentTick,
        int256 minTick,
        int256 maxTick,
        int256 minLiquidity,
        int256 maxLiquidity
    ) private pure returns (string memory) {
        int256 axisMinLiquidity = minLiquidity / 2;
        int256 axisMaxLiquidity = (maxLiquidity * 11) / 10; // 110% of max

        int256 axisMinTick = minTick - (tickData[1] - tickData[0]);
        int256 axisMaxTick = maxTick + (tickData[1] - tickData[0]);

        string memory axes = string(
            abi.encodePacked(
                '<line x1="',
                uint256(PADDING).toString(),
                '" y1="',
                uint256(HEIGHT - PADDING).toString()
            )
        );
        axes = string(
            abi.encodePacked(
                axes,
                '" x2="',
                uint256(WIDTH - PADDING).toString(),
                '" y2="',
                uint256(HEIGHT - PADDING).toString(),
                '" stroke="black" />'
            )
        );
        axes = string(
            abi.encodePacked(
                axes,
                '<line x1="',
                uint256(PADDING).toString(),
                '" y1="',
                uint256(PADDING).toString()
            )
        );
        axes = string(
            abi.encodePacked(
                axes,
                '" x2="',
                uint256(PADDING).toString(),
                '" y2="',
                uint256(HEIGHT - PADDING).toString(),
                '" stroke="black" />'
            )
        );
        axes = string(abi.encodePacked(axes, generateXAxisTick(minTick, axisMinTick, axisMaxTick)));
        axes = string(
            abi.encodePacked(axes, generateXAxisTick(currentTick, axisMinTick, axisMaxTick))
        );
        axes = string(abi.encodePacked(axes, generateXAxisTick(maxTick, axisMinTick, axisMaxTick)));
        axes = string(
            abi.encodePacked(
                axes,
                generateYAxisTick(minLiquidity, axisMinLiquidity, axisMaxLiquidity)
            )
        );
        axes = string(
            abi.encodePacked(
                axes,
                generateYAxisTick(maxLiquidity, axisMinLiquidity, axisMaxLiquidity)
            )
        );

        return axes;
    }

    function generateXAxisTick(
        int256 value,
        int256 minTick,
        int256 maxTick
    ) private pure returns (string memory) {
        int256 x = ((value - minTick) * (WIDTH - 2 * PADDING)) / (maxTick - minTick) + PADDING;
        return
            string(
                abi.encodePacked(
                    '<line x1="',
                    toStringSigned(x),
                    '" y1="',
                    uint256(HEIGHT - PADDING).toString(),
                    '" x2="',
                    toStringSigned(x),
                    '" y2="',
                    uint256(HEIGHT - PADDING + 5).toString(),
                    '" stroke="black" />',
                    '<text x="',
                    toStringSigned(x),
                    '" y="',
                    uint256(HEIGHT - PADDING + 15).toString(),
                    '" font-size="7" text-anchor="middle">',
                    toStringSigned(value),
                    "</text>"
                )
            );
    }

    function generateYAxisTick(
        int256 value,
        int256 minLiquidity,
        int256 maxLiquidity
    ) private pure returns (string memory) {
        int256 y = HEIGHT -
            (((value - minLiquidity) * (HEIGHT - 2 * PADDING)) /
                (maxLiquidity - minLiquidity) +
                PADDING);
        return
            string(
                abi.encodePacked(
                    '<line x1="',
                    uint256(PADDING).toString(),
                    '" y1="',
                    toStringSigned(y),
                    '" x2="',
                    uint256(PADDING - 5).toString(),
                    '" y2="',
                    toStringSigned(y),
                    '" stroke="black" />',
                    '<text x="',
                    uint256(PADDING - 4).toString(),
                    '" y="',
                    toStringSigned(y),
                    '" font-size="6" text-anchor="end" dominant-baseline="middle">',
                    toStringSigned(value),
                    "</text>"
                )
            );
    }

    function findMinMax(
        int256[] memory tickData,
        int256[] memory liquidityData
    ) private pure returns (int256, int256, int256, int256) {
        int256 minTick = tickData[0];
        int256 maxTick = tickData[tickData.length - 1];
        int256 minLiquidity = liquidityData[0];
        int256 maxLiquidity = liquidityData[0];

        for (uint i = 1; i < liquidityData.length; i++) {
            if (liquidityData[i] < minLiquidity) minLiquidity = liquidityData[i];
            if (liquidityData[i] > maxLiquidity) maxLiquidity = liquidityData[i];
        }

        return (minTick, maxTick, minLiquidity, maxLiquidity);
    }

    function generateBase64EncodedSVG(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int256 currentTick,
        uint256 chartType
    ) public pure returns (string memory) {
        string memory svg = generateSVGChart(tickData, liquidityData, currentTick, chartType);
        return string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg))));
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
}
