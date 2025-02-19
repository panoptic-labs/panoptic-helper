// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";

/// @title PriceFlipAdapter
/// @notice This contract is a wrapper around an IV3CompatibleOracle that flips the price and tick values from token1/token0 to token0/token1
/// @dev This is useful for working with Uniswap V4 pools where the token order (e.g. ETH/USDC) diverges from the V3 equivalent (e.g. USDC/WETH)
/// @author Axicon Labs Limited
contract PriceFlipAdapter {
    /// @notice The underlying Uniswap V3-compatible oracle to operate this adapter on.
    IV3CompatibleOracle public immutable underlying;

    /// @notice Sets the underlying oracle to operate on.
    /// @param _underlying The underlying oracle to operate on
    constructor(IV3CompatibleOracle _underlying) {
        underlying = _underlying;
    }

    /// @notice The 0th storage slot in the underlying oracle stores many values, and is exposed as a single method to save gas
    /// when accessed externally.
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    /// @return tick The current tick of the pool, i.e. according to the last tick transition that was run.
    /// This value may not always be equal to SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
    /// boundary.
    /// @return observationIndex The index of the last oracle observation that was written,
    /// @return observationCardinality The current maximum number of observations stored in the pool,
    /// @return observationCardinalityNext The next maximum number of observations, to be updated when the observation.
    /// @return feeProtocol The protocol fee for both tokens of the pool.
    /// Encoded as two 4 bit values, where the protocol fee of token1 is shifted 4 bits and the protocol fee of token0
    /// is the lower 4 bits. Used as the denominator of a fraction of the swap fee, e.g. 4 means 1/4th of the swap fee.
    /// unlocked Whether the pool is currently locked to reentrancy
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        (
            sqrtPriceX96,
            tick,
            observationIndex,
            observationCardinality,
            observationCardinalityNext,
            feeProtocol,
            unlocked
        ) = underlying.slot0();

        tick = -tick;
        sqrtPriceX96 = uint160(uint256(2 ** 192) / sqrtPriceX96);
    }

    /// @notice Returns data about a specific observation index on the underlying oracle.
    /// @param index The element of the observations array to fetch
    /// @return blockTimestamp The timestamp of the observation
    /// @return tickCumulative The tick multiplied by seconds elapsed for the life of the pool as of the observation timestamp
    /// @return secondsPerLiquidityCumulativeX128 The seconds per in range liquidity for the life of the pool as of the observation timestamp
    /// @return initialized Whether the observation has been initialized and the values are safe to use
    function observations(
        uint256 index
    )
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        (
            blockTimestamp,
            tickCumulative,
            secondsPerLiquidityCumulativeX128,
            initialized
        ) = underlying.observations(index);
        tickCumulative = -tickCumulative;
    }

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp on the underlying oracle.
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of currency1 / currency0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value as of each `secondsAgos` from the current block
    /// timestamp
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        (tickCumulatives, secondsPerLiquidityCumulativeX128s) = underlying.observe(secondsAgos);

        for (uint256 i = 0; i < tickCumulatives.length; i++) {
            tickCumulatives[i] = -tickCumulatives[i];
        }
    }

    /// @notice Increase the maximum number of price and liquidity observations that the underlying oracle will store.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external {
        underlying.increaseObservationCardinalityNext(observationCardinalityNext);
    }
}
