// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {BaseHook} from "v4-periphery/base/hooks/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice A hook for a pool that allows a Uniswap V4 pool to expose a V3-compatible oracle interface
contract V3StyleOracle is BaseHook {
    using Oracle for Oracle.Observation[65535];
    using StateLibrary for IPoolManager;

    /// @notice Only the canonical Uniswap pool manager may call this function
    error NotManager();

    /// @notice This oracle contract can only respond to hook calls related to the `underlyingPoolId` set during construction
    error PoolNotUnderlying();

    /// @notice Emitted by the hook for increases to the number of observations that can be stored.
    /// @dev `observationCardinalityNext` is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    /// @notice Contains information about the current number of observations stored.
    /// @param observationIndex The most-recently updated index of the observations buffer
    /// @param observationCardinality The current maximum number of observations that are being stored
    /// @param observationCardinalityNext The next maximum number of observations that can be stored
    struct ObservationState {
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
    }

    /// @notice The pool id (hashed pool key) of the underlying pool.
    PoolId public immutable underlyingPoolId;

    /// @notice The canonical Uniswap V4 pool manager.
    IPoolManager public immutable manager;

    /// @notice Returns information about the current number of observations stored.
    ObservationState public observationState;

    /// @notice Returns data about a specific observation index.
    Oracle.Observation[65535] public observations;

    /// @notice Reverts if the caller is not the canonical Uniswap V4 pool manager.
    modifier onlyByManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    /// @notice Initializes a Uniswap V4 pool with this hook, stores baseline observation state, and optionally performs a cardinality increase.
    /// @param _manager The canonical Uniswap V4 pool manager
    /// @param underlyingPool The pool key of the underlying pool (the hook address will be replaced with this contract's address)
    /// @param sqrtPriceX96 The initial sqrt(price) of the pool as a Q64.96
    /// @param cardinalityIncrease The number of slots (if any) to increase the observation cardinality by
    constructor(
        IPoolManager _manager,
        PoolKey memory underlyingPool,
        uint160 sqrtPriceX96,
        uint16 cardinalityIncrease
    ) BaseHook(_manager) {
        underlyingPool.hooks = IHooks(address(this));

        underlyingPoolId = underlyingPool.toId();

        _manager.initialize(underlyingPool, sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
            uint32(block.timestamp)
        );

        manager = _manager;
        observationState = ObservationState({
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });

        if (cardinalityIncrease > 0) increaseObservationCardinalityNext(cardinalityIncrease);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @inheritdoc BaseHook
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external view override onlyByManager returns (bytes4) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(underlyingPoolId))
            revert PoolNotUnderlying();

        return this.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override onlyByManager returns (bytes4, BeforeSwapDelta, uint24) {
        ObservationState memory _observationState = observationState;

        (, int24 tick, , ) = manager.getSlot0(underlyingPoolId);

        (observationState.observationIndex, observationState.observationCardinality) = observations
            .write(
                _observationState.observationIndex,
                uint32(block.timestamp),
                tick,
                _observationState.observationCardinality,
                _observationState.observationCardinalityNext
            );
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Emulates the behavior of the exposed zeroth slot of a Uniswap V3 pool.
    /// @dev The last two values are not meaningful in the context of this oracle contract, but are returned to maintain interface compatibility.
    /// @return The current price of the oracle as a sqrt(currency1/currency0) Q64.96 value
    /// @return The current tick of the oracle, i.e. according to the last tick transition that was run.
    /// This value may not always be equal to SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
    /// boundary
    /// @return The index of the last oracle observation that was written
    /// @return The current maximum number of observations stored in the oracle
    /// @return The next maximum number of observations that can be stored in the oracle once the highest observation index is written
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        (uint160 sqrtPriceX96, int24 tick, , ) = manager.getSlot0(underlyingPoolId);

        return (
            sqrtPriceX96,
            tick,
            observationState.observationIndex,
            observationState.observationCardinality,
            observationState.observationCardinalityNext,
            0,
            true
        );
    }

    /// @notice Returns the cumulative tick as of each timestamp `secondsAgo` from the current block timestamp.
    /// @dev Note that the second return value, seconds per liquidity, is not implemented in this oracle hook and will always return 0 -- it has been retained for interface compatibility.
    /// @dev To get a time weighted average tick, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of currency1 / currency0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory) {
        ObservationState memory _observationState = observationState;

        (, int24 tick, , ) = manager.getSlot0(underlyingPoolId);

        return (
            observations.observe(
                uint32(block.timestamp),
                secondsAgos,
                tick,
                _observationState.observationIndex,
                _observationState.observationCardinality
            ),
            new uint160[](0)
        );
    }

    /// @notice Increase the maximum number of price and liquidity observations that this oracle will store.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) public {
        uint16 observationCardinalityNextOld = observationState.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        observationState.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
    }
}
