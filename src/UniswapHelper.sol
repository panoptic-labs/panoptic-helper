// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

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
            maxLiquidity
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
        int256 maxLiquidity
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
        (int256[] memory tickData, int256[] memory liquidityData) = getTickNets(univ3pool);

        (, int24 currentTick, , , , , ) = univ3pool.slot0();

        uint24 feeTier = univ3pool.fee();
        string memory symbol0 = ERC20(univ3pool.token0()).symbol();
        string memory symbol1 = ERC20(univ3pool.token1()).symbol();

        string memory title = string(
            abi.encodePacked(symbol0, "-", symbol1, "-", uint256(feeTier / 100).toString(), "bps")
        );

        return generateBase64PoolSVG(tickData, liquidityData, currentTick, 1, title);
    }

    function plotPnL(uint256 tokenId) public view returns (string memory) {}
}
