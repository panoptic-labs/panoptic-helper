// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;
import "forge-std/Test.sol";

// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract UniswapHelper {
    IUniswapV3Factory internal immutable FACTORY;
    INonfungiblePositionManager immutable NFPM;
    SemiFungiblePositionManager internal immutable SFPM;

    using Strings for uint256;

    // Constants for chart dimensions
    int256 private constant WIDTH = 500;
    int256 private constant HEIGHT = 300;
    int256 private constant PADDING = 40;
    int256 private constant TITLE_HEIGHT = 20;

    /// @notice Construct the PanopticHelper contract
    /// @param _factory address of the Uniswap factory
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _NFPM,
        SemiFungiblePositionManager _SFPM
    ) payable {
        FACTORY = _factory;
        NFPM = _NFPM;
        SFPM = _SFPM;
    }

    function getTickNets(
        IUniswapV3Pool univ3pool
    ) internal view returns (int256[] memory, int256[] memory) {
        (, int24 currentTick, , , , , ) = univ3pool.slot0();
        int24 tickSpacing = univ3pool.tickSpacing();
        int256 scaledTick = int256((currentTick / tickSpacing) * tickSpacing);

        int256[] memory tickData = new int256[](301);
        int256[] memory liquidityNets = new int256[](301);

        uint256 i;
        for (int256 dt = -150; dt < 150; ) {
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

    function toStringSignedPct(int256 value) internal pure returns (string memory) {
        if (value < 0) {
            return
                string(
                    abi.encodePacked(
                        "-",
                        uint256(-value / 100).toString(),
                        ".",
                        ((-value % 100) < 10) ? "0" : "",
                        uint256(-value % 100).toString()
                    )
                );
        } else {
            return
                string(
                    abi.encodePacked(
                        uint256(value / 100).toString(),
                        ".",
                        ((value % 100) < 10) ? "0" : "",
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

    function generatePoolSVGChart(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int256 currentTick,
        uint256 chartType,
        string memory title
    ) internal pure returns (string memory) {
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
                '<rect width="100%" height="100%" fill="white"/><defs><linearGradient id="lineGradient" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" style="stop-color:rgba(91,12,214,0.75)"/><stop offset="100%" style="stop-color:rgba(91,12,214,0)"/></linearGradient><linearGradient id="barGradientBelow" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" style="stop-color:rgba(91,12,214,0.5)"/><stop offset="100%" style="stop-color:rgba(91,12,214,0.65)"/></linearGradient><linearGradient id="barGradientAbove" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" style="stop-color:rgba(155,12,214,0.5)"/><stop offset="100%" style="stop-color:rgba(155,12,214,0.65)"/></linearGradient></defs>'
            )
        );

        string memory chartTitle = generateTitle(title);

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
            maxLiquidity,
            "tick",
            "liquidity (token0)"
        );

        string memory secondaryAxes = generateSecondaryYAxes(0, 0);

        string memory svgEnd = "</svg>";
        return
            string(abi.encodePacked(svgStart, chartTitle, chartData, axes, secondaryAxes, svgEnd));
    }

    function generateTitle(string memory title) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<text x="',
                    uint256(WIDTH / 2).toString(),
                    '" y="',
                    uint256(TITLE_HEIGHT / 2).toString(),
                    '" font-size="12" text-anchor="middle" dominant-baseline="middle">',
                    title,
                    "</text>"
                )
            );
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
                    '" fill="url(#lineGradient)" stroke="rgba(91,12,241,1)" stroke-width="2"/>'
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
        int256 barWidth = (((100 * (WIDTH - 2 * PADDING)) / int256(tickData.length + 1)) * 92) /
            100; // fill available width, just about

        minLiquidity = minLiquidity / 2;
        maxLiquidity = (maxLiquidity * 11) / 10;

        minTick = minTick - (tickData[1] - tickData[0]);
        maxTick = maxTick + (tickData[1] - tickData[0]);

        for (uint i = 0; i < tickData.length; i++) {
            int256 _tick = tickData[i];
            int256 _liquidity = liquidityData[i];
            int256 x = (100 * (_tick - minTick) * (WIDTH - 2 * PADDING)) /
                (maxTick - minTick) +
                100 *
                PADDING;
            int256 y = HEIGHT -
                (((_liquidity - minLiquidity) * (HEIGHT - 2 * PADDING)) /
                    (maxLiquidity - minLiquidity) +
                    PADDING);
            int256 barHeight = HEIGHT - y - PADDING;

            string memory barProps;
            {
                bool aboveCurrent = _tick > currentTick;
                barProps = string(
                    abi.encodePacked(
                        '<rect x="',
                        toStringSignedPct(x - (barWidth) / 2),
                        '" y="',
                        toStringSignedPct(100 * y),
                        '" width="',
                        toStringSignedPct(barWidth),
                        '" height="',
                        toStringSignedPct(100 * barHeight),
                        '" fill="url(#',
                        aboveCurrent ? "barGradientAbove" : "barGradientBelow",
                        ')" stroke="white" stroke-width="0.25" />'
                    )
                );
            }

            bars = string(abi.encodePacked(bars, barProps));
        }

        {
            int256 currentTickX = ((currentTick - minTick) * (WIDTH - 2 * PADDING)) /
                (maxTick - minTick) +
                PADDING;
            // Add the vertical line for the current tick
            string memory currentTickLine = string(
                abi.encodePacked(
                    uint256(currentTickX).toString(),
                    '" y1="',
                    uint256(PADDING).toString(),
                    '" x2="',
                    uint256(currentTickX).toString(),
                    '" y2="',
                    uint256(HEIGHT - PADDING).toString()
                )
            );
            currentTickLine = string(
                abi.encodePacked(
                    '<line x1="',
                    currentTickLine,
                    '" stroke="white" stroke-width="1.5" /><line x1="',
                    currentTickLine,
                    '" stroke="deeppink" stroke-width="0.75" opacity="0.8" />'
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
        int256 maxLiquidity,
        string memory xAxisLabel,
        string memory yAxisLabel
    ) private pure returns (string memory) {
        int256 axisMinLiquidity = minLiquidity / 2;
        int256 axisMaxLiquidity = (maxLiquidity * 11) / 10; // 110% of max

        int256 axisMinTick = minTick - (tickData[1] - tickData[0]);
        int256 axisMaxTick = maxTick + (tickData[1] - tickData[0]);

        // x-axis line
        string memory axes = string(
            abi.encodePacked(
                '<line x1="',
                uint256(PADDING).toString(),
                '" y1="',
                uint256(HEIGHT - PADDING).toString()
            )
        );

        // y-axis line
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

        // Add x-axis label
        axes = string(
            abi.encodePacked(
                axes,
                '<text x="',
                uint256(WIDTH - PADDING - 40).toString(),
                '" y="',
                uint256(HEIGHT + TITLE_HEIGHT - 35).toString(),
                '" font-family="Arial, sans-serif" font-size="9" text-anchor="middle">',
                xAxisLabel,
                "</text>"
            )
        );

        // Add y-axis label
        axes = string(
            abi.encodePacked(
                axes,
                '<text x="',
                uint256(10).toString(),
                '" y="',
                uint256((HEIGHT + TITLE_HEIGHT) / 2).toString(),
                '" font-family="Arial, sans-serif" font-size="9" text-anchor="middle" transform="rotate(-90, 10, ',
                uint256((HEIGHT + TITLE_HEIGHT) / 2).toString(),
                ')">',
                yAxisLabel,
                "</text>"
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
                    uint256(PADDING - 6).toString(),
                    '" y="',
                    toStringSigned(y),
                    '" font-size="6" text-anchor="end" dominant-baseline="middle">',
                    toStringSignedPct(value),
                    "</text>"
                )
            );
    }

    function generateSecondaryYAxes(
        int256 minLiquidity,
        int256 maxLiquidity
    ) private pure returns (string memory) {
        string memory axes = "";

        // Generate secondary y-axis (right) if minLiquidity != maxLiquidity
        if (minLiquidity != maxLiquidity) {
            axes = string(
                abi.encodePacked(
                    axes,
                    '<line x1="',
                    uint256(WIDTH - PADDING).toString(),
                    '" y1="',
                    uint256(PADDING).toString(),
                    '" x2="',
                    uint256(WIDTH - PADDING).toString(),
                    '" y2="',
                    uint256(HEIGHT - PADDING).toString(),
                    '" stroke="green" />',
                    generateSecondaryYAxisTick(minLiquidity, minLiquidity, maxLiquidity),
                    generateSecondaryYAxisTick(maxLiquidity, minLiquidity, maxLiquidity)
                )
            );
        }

        return axes;
    }

    function generateSecondaryXAxisTick(
        int256 value,
        int256 minTick,
        int256 maxTick
    ) private pure returns (string memory) {
        int256 x = ((value - minTick) * (WIDTH - 2 * PADDING)) / (maxTick - minTick) + PADDING;
        return
            string(
                abi.encodePacked(
                    '<line x1="',
                    uint256(x).toString(),
                    '" y1="',
                    uint256(PADDING + TITLE_HEIGHT).toString(),
                    '" x2="',
                    uint256(x).toString(),
                    '" y2="',
                    uint256(PADDING + TITLE_HEIGHT - 5).toString(),
                    '" stroke="black" />',
                    '<text x="',
                    uint256(x).toString(),
                    '" y="',
                    uint256(PADDING + TITLE_HEIGHT - 10).toString(),
                    '" font-size="10" text-anchor="middle">',
                    toStringSigned(value),
                    "</text>"
                )
            );
    }

    function generateSecondaryYAxisTick(
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
                    uint256(WIDTH - PADDING).toString(),
                    '" y1="',
                    uint256(y).toString(),
                    '" x2="',
                    uint256(WIDTH - PADDING + 5).toString(),
                    '" y2="',
                    uint256(y).toString(),
                    '" stroke="black" />',
                    '<text x="',
                    uint256(WIDTH - PADDING + 10).toString(),
                    '" y="',
                    uint256(y).toString(),
                    '" font-size="10" text-anchor="start" dominant-baseline="middle">',
                    toStringSigned(value),
                    "</text>"
                )
            );
    }

    function recastLiquidity(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int24 currentTick,
        uint256 decimals0
    ) private pure returns (int256[] memory) {
        int256[] memory recastedLiquidity = new int256[](liquidityData.length);

        int24 tickSpacing = int24(tickData[2] - tickData[1]);

        for (uint256 i; i < tickData.length; ++i) {
            (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
                currentTick,
                uint128(uint256(liquidityData[i])),
                int24(tickData[i]),
                int24(tickData[i] + tickSpacing)
            );
            recastedLiquidity[i] =
                (int256(amount0) +
                    int256(convert1to0(amount1, getSqrtRatioAtTick(int24(tickData[i]))))) /
                int256(10 ** (decimals0 - 2));
        }

        return recastedLiquidity;
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

    function generateBase64PoolSVG(
        int256[] memory tickData,
        int256[] memory liquidityData,
        int256 currentTick,
        uint256 chartType,
        string memory title
    ) internal pure returns (string memory) {
        string memory svg = generatePoolSVGChart(
            tickData,
            liquidityData,
            currentTick,
            chartType,
            title
        );
        return string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg))));
    }

    function plotPoolLiquidity(address pool) public view returns (string memory) {
        IUniswapV3Pool univ3pool = IUniswapV3Pool(pool);

        (, int24 currentTick, , , , , ) = univ3pool.slot0();
        uint256 decimals0 = ERC20(univ3pool.token0()).decimals();

        (int256[] memory tickData, int256[] memory liquidityData) = getTickNets(univ3pool);

        // recard liquidityData into token0
        liquidityData = recastLiquidity(tickData, liquidityData, int24(currentTick), decimals0);

        string memory title;

        {
            uint24 feeTier = univ3pool.fee();
            string memory symbol0 = ERC20(univ3pool.token0()).symbol();
            string memory symbol1 = ERC20(univ3pool.token1()).symbol();

            title = string(
                abi.encodePacked(
                    symbol0,
                    "-",
                    symbol1,
                    "-",
                    uint256(feeTier / 100).toString(),
                    "bps"
                )
            );
        }
        return generateBase64PoolSVG(tickData, liquidityData, currentTick, 1, title);
    }

    function plotPnL(uint256 tokenId) public view returns (string memory) {}

    /// @notice Calculates 1.0001^(tick/2) as an X96 number.
    /// @dev Implemented using Uniswap's "incorrect" constants. Supplying commented-out real values for an accurate calculation.
    /// @dev Will revert if |tick| > max tick.
    /// @param tick Value of the tick for which sqrt(1.0001^tick) is calculated
    /// @return A Q64.96 number representing the sqrt price at the provided tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(887272))) revert();

            // sqrt(1.0001^(-absTick)) = ∏ sqrt(1.0001^(-bit_i))
            // ex: absTick = 100 = binary 1100100, so sqrt(1.0001^-100) = sqrt(1.0001^-64) * sqrt(1.0001^-32) * sqrt(1.0001^-4)
            // constants are 2^128/(sqrt(1.0001)^bit_i) rounded half-up

            // if the first bit is 0, initialize sqrtR to 1 (2^128)
            uint256 sqrtR = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;

            if (absTick & 0x2 != 0) sqrtR = (sqrtR * 0xfff97272373d413259a46990580e213a) >> 128;

            if (absTick & 0x4 != 0) sqrtR = (sqrtR * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;

            if (absTick & 0x8 != 0) sqrtR = (sqrtR * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;

            if (absTick & 0x10 != 0) sqrtR = (sqrtR * 0xffcb9843d60f6159c9db58835c926644) >> 128;

            if (absTick & 0x20 != 0) sqrtR = (sqrtR * 0xff973b41fa98c081472e6896dfb254c0) >> 128;

            if (absTick & 0x40 != 0) sqrtR = (sqrtR * 0xff2ea16466c96a3843ec78b326b52861) >> 128;

            if (absTick & 0x80 != 0) sqrtR = (sqrtR * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;

            if (absTick & 0x100 != 0) sqrtR = (sqrtR * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;

            if (absTick & 0x200 != 0) sqrtR = (sqrtR * 0xf987a7253ac413176f2b074cf7815e54) >> 128;

            if (absTick & 0x400 != 0) sqrtR = (sqrtR * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;

            if (absTick & 0x800 != 0) sqrtR = (sqrtR * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;

            if (absTick & 0x1000 != 0) sqrtR = (sqrtR * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;

            if (absTick & 0x2000 != 0) sqrtR = (sqrtR * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;

            if (absTick & 0x4000 != 0) sqrtR = (sqrtR * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;

            if (absTick & 0x8000 != 0) sqrtR = (sqrtR * 0x31be135f97d08fd981231505542fcfa6) >> 128;

            if (absTick & 0x10000 != 0) sqrtR = (sqrtR * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;

            if (absTick & 0x20000 != 0) sqrtR = (sqrtR * 0x5d6af8dedb81196699c329225ee604) >> 128;

            if (absTick & 0x40000 != 0) sqrtR = (sqrtR * 0x2216e584f5fa1ea926041bedfe98) >> 128;

            if (absTick & 0x80000 != 0) sqrtR = (sqrtR * 0x48a170391f7dc42444e8fa2) >> 128;

            // 2^128 * sqrt(1.0001^x) = 2^128 / sqrt(1.0001^-x)
            if (tick > 0) sqrtR = type(uint256).max / sqrtR;

            // Downcast + rounding up to keep is consistent with Uniswap's
            return uint160((sqrtR >> 32) + (sqrtR % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice Calculates the amount of token0 received for a given LiquidityChunk.
    /// @return The amount of token0
    function getAmount0ForLiquidity(
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(tickLower);
        uint160 highPriceX96 = getSqrtRatioAtTick(tickUpper);
        unchecked {
            return
                mulDiv(uint256(liquidity) << 96, highPriceX96 - lowPriceX96, highPriceX96) /
                lowPriceX96;
        }
    }

    /// @notice Calculates the amount of token1 received for a given LiquidityChunk.
    /// @return The amount of token1
    function getAmount1ForLiquidity(
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256) {
        uint160 lowPriceX96 = getSqrtRatioAtTick(tickLower);
        uint160 highPriceX96 = getSqrtRatioAtTick(tickUpper);

        unchecked {
            return mulDiv96(liquidity, highPriceX96 - lowPriceX96);
        }
    }

    /// @notice Calculates the amount of token0 and token1 received for a given LiquidityChunk at the provided currentTick.
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        int24 currentTick,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (currentTick <= tickLower) {
            amount0 = getAmount0ForLiquidity(liquidity, tickLower, tickUpper);
        } else if (currentTick >= tickUpper) {
            amount1 = getAmount1ForLiquidity(liquidity, tickLower, tickUpper);
        } else {
            amount0 = getAmount0ForLiquidity(liquidity, currentTick, tickUpper);
            amount1 = getAmount1ForLiquidity(liquidity, tickLower, currentTick);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           MULDIV ALGORITHMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0);
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////
            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly ("memory-safe") {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the preconditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
        }
    }

    /// @notice Calculates floor(a×b÷2^96) with full precision. Throws if result overflows a uint256.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @return The 256-bit result
    function mulDiv96(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                uint256 res;
                assembly ("memory-safe") {
                    // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                    res := shr(96, prod0)
                }
                return res;
            }

            // Make sure the result is less than 2**256.
            require(2 ** 96 > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, 0x1000000000000000000000000)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Divide [prod1 prod0] by the factors of two (note that this is just 2**96 since the denominator is a power of 2 itself)
            assembly ("memory-safe") {
                // Right shift by n is equivalent and 2 gas cheaper than division by 2^n
                prod0 := shr(96, prod0)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            // Note that this is just 2**160 since 2**256 over the fixed denominator (2**96) equals 2**160
            prod0 |= prod1 * 2 ** 160;

            return prod0;
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as sqrt(1/0)*2^96.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
    function convert1to0(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return mulDiv(amount, 2 ** 192, uint256(sqrtPriceX96) ** 2);
            } else {
                return mulDiv(amount, 2 ** 128, mulDiv(sqrtPriceX96, sqrtPriceX96, 2 ** 64));
            }
        }
    }
}
