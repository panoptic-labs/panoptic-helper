// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
// import {OracleTest} from "univ3-core/test/OracleTest.sol";
import {V3StyleOracle} from "../src/hooks/V3StyleOracle.sol";
import {V3OracleAdapter} from "../src/adapters/V3OracleAdapter.sol";
import {V3TruncatedOracleAdapter} from "../src/adapters/V3TruncatedOracleAdapter.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ERC20S} from "@testutils-v1-core/ERC20S.sol";
import {V4RouterSimple} from "@testutils-v1-core/V4RouterSimple.sol";
import {TickMath} from "univ3-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract OracleTestV4 is Test {
    IPoolManager public immutable manager;

    V3StyleOracle public constant oracleBase =
        V3StyleOracle(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));

    V3OracleAdapter public oracleAdapter;

    V3TruncatedOracleAdapter public truncatedOracleAdapter;

    V4RouterSimple public routerV4;

    ERC20S public token0;
    ERC20S public token1;

    PoolKey public poolKey;

    struct InitializeParams {
        uint32 time;
        int24 tick;
    }

    struct UpdateParams {
        uint32 advanceTimeBy;
        int24 tick;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
        routerV4 = new V4RouterSimple(_manager);

        token0 = new ERC20S("Token0", "T0", 18);
        token0.mint(address(this), 2 ** 125);
        token0.approve(address(routerV4), 2 ** 125);
        token1 = new ERC20S("Token1", "T1", 18);
        token1.mint(address(this), 2 ** 125);
        token1.approve(address(routerV4), 2 ** 125);

        if (address(token1) < address(token0)) (token0, token1) = (token1, token0);
    }

    function initialize(InitializeParams memory params) public {
        vm.warp(params.time);
        deployCodeTo("V3StyleOracle.sol", abi.encode(manager, int24(9116)), address(oracleBase));
        vm.recordLogs();

        manager.initialize(
            PoolKey({
                currency0: Currency.wrap(address(token0)),
                currency1: Currency.wrap(address(token1)),
                fee: 3000,
                tickSpacing: 1,
                hooks: IHooks(address(oracleBase))
            }),
            TickMath.getSqrtRatioAtTick(params.tick)
        );

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(oracleBase))
        });

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (oracleAdapter, truncatedOracleAdapter) = abi.decode(
            entries[1].data,
            (V3OracleAdapter, V3TruncatedOracleAdapter)
        );

        routerV4.modifyLiquidity(address(0), poolKey, -887270, 887270, 100);
    }

    function grow(uint16 _cardinality) public {
        oracleAdapter.increaseObservationCardinalityNext(_cardinality);
    }

    function update(UpdateParams memory params) public {
        vm.warp(block.timestamp + params.advanceTimeBy);
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(params.tick));
    }

    function index() public view returns (uint16) {
        (, , uint16 observationIndex, , , , ) = oracleAdapter.slot0();
        return observationIndex;
    }

    function cardinality() public view returns (uint16) {
        (, , , uint16 observationCardinality, , , ) = oracleAdapter.slot0();
        return observationCardinality;
    }

    function cardinalityNext() public view returns (uint16) {
        (, , , , uint16 observationCardinalityNext, , ) = oracleAdapter.slot0();
        return observationCardinalityNext;
    }

    function observations(
        uint256 _index
    )
        public
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return oracleAdapter.observations(_index);
    }
}

contract OracleLibTest is Test {
    OracleTestV4 public oracle;
    V3OracleAdapter public oracleAdapter;
    uint256 constant TEST_POOL_START_TIME = 1;
    uint128 constant MAX_UINT128 = type(uint128).max;

    function setUp() public {
        oracle = new OracleTestV4(new PoolManager(address(this)));
    }

    function test_initialize_indexIsZero() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.index(), 0);
    }

    function test_initialize_cardinalityIsOne() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.cardinality(), 1);
    }

    function test_initialize_cardinalityNextIsOne() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.cardinalityNext(), 1);
    }

    function test_initialize_firstSlotTimestamp() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        ) = oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);
    }

    function test_grow_increasesCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(5);
        assertEq(oracle.index(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityNext(), 5);
    }

    function test_grow_doesNotTouchFirstSlot() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(5);
        (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        ) = oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);
    }

    function test_grow_isNoOpIfAlreadyLargerSize() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(5);
        oracle.grow(3);
        assertEq(oracle.index(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityNext(), 5);
    }

    function test_update_singleElementArrayOverwrite() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));

        // First update
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 2}));
        assertEq(oracle.index(), 0);
        (uint32 blockTimestamp, int56 tickCumulative, , bool initialized) = oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);

        // Second update
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 5, tick: -1}));
        (blockTimestamp, tickCumulative, , initialized) = oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 10);
    }

    // function test_update_doesNothingIfTimeHasNotChanged() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 0,
    //         tick: 0,
    //         liquidity: 0
    //     }));
    //     oracle.grow(2);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 1,
    //         tick: 3,
    //         liquidity: 2
    //     }));
    //     assertEq(oracle.index(), 1);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 0,
    //         tick: -5,
    //         liquidity: 9
    //     }));
    //     assertEq(oracle.index(), 1);
    // }

    // function test_update_writesIndexIfTimeHasChanged() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 0,
    //         tick: 0,
    //         liquidity: 0
    //     }));
    //     oracle.grow(3);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 6,
    //         tick: 3,
    //         liquidity: 2
    //     }));
    //     assertEq(oracle.index(), 1);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 4,
    //         tick: -5,
    //         liquidity: 9
    //     }));
    //     assertEq(oracle.index(), 2);

    //     (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) = oracle.observations(1);
    //     assertTrue(initialized);
    //     assertEq(blockTimestamp, 6);
    //     assertEq(tickCumulative, 0);
    //     assertEq(secondsPerLiquidityCumulativeX128, uint160(2041694201525630780780247644590609268736));
    // }

    // function test_update_wrapsAround() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 0,
    //         tick: 0,
    //         liquidity: 0
    //     }));
    //     oracle.grow(3);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 3,
    //         tick: 1,
    //         liquidity: 2
    //     }));
    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 4,
    //         tick: 2,
    //         liquidity: 3
    //     }));
    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 5,
    //         tick: 3,
    //         liquidity: 4
    //     }));

    //     assertEq(oracle.index(), 0);

    //     (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) = oracle.observations(0);
    //     assertTrue(initialized);
    //     assertEq(blockTimestamp, 12);
    //     assertEq(tickCumulative, 14);
    //     assertEq(secondsPerLiquidityCumulativeX128, uint160(2268549112806256423089164049545121409706));
    // }

    // function test_update_accumulates_liquidity() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 0,
    //         tick: 0,
    //         liquidity: 0
    //     }));
    //     oracle.grow(4);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 3,
    //         tick: 3,
    //         liquidity: 2
    //     }));
    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 4,
    //         tick: -7,
    //         liquidity: 6
    //     }));
    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 5,
    //         tick: -2,
    //         liquidity: 4
    //     }));

    //     assertEq(oracle.index(), 3);

    //     (uint32 blockTimestamp1, int56 tickCumulative1, uint160 secondsPerLiquidityCumulativeX128_1, bool initialized1) = oracle.observations(1);
    //     assertTrue(initialized1);
    //     assertEq(blockTimestamp1, 3);
    //     assertEq(tickCumulative1, 0);
    //     assertEq(secondsPerLiquidityCumulativeX128_1, uint160(1020847100762815390390123822295304634368));

    //     (uint32 blockTimestamp2, int56 tickCumulative2, uint160 secondsPerLiquidityCumulativeX128_2, bool initialized2) = oracle.observations(2);
    //     assertTrue(initialized2);
    //     assertEq(blockTimestamp2, 7);
    //     assertEq(tickCumulative2, 12);
    //     assertEq(secondsPerLiquidityCumulativeX128_2, uint160(1701411834604692317316873037158841057280));

    //     (uint32 blockTimestamp3, int56 tickCumulative3, uint160 secondsPerLiquidityCumulativeX128_3, bool initialized3) = oracle.observations(3);
    //     assertTrue(initialized3);
    //     assertEq(blockTimestamp3, 12);
    //     assertEq(tickCumulative3, -23);
    //     assertEq(secondsPerLiquidityCumulativeX128_3, uint160(1984980473705474370203018543351981233493));
    // }

    // function test_observe_fails_if_older_observation_not_exist() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 1;
    //     vm.expectRevert();
    //     oracle.observe(secondsAgos);
    // }

    // function test_observe_works_across_overflow_boundary() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: type(uint32).max - 1,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     oracle.advanceTime(2);
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 1;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);
    //     assertEq(tickCumulatives[0], 2);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(85070591730234615865843651857942052864));
    // }

    // function test_observe_single_observation_at_current_time() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 0;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);
    //     assertEq(tickCumulatives[0], 0);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    // }

    // function test_observe_single_observation_in_past_but_not_earlier_than_secondsAgo() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     oracle.advanceTime(3);
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 4;
    //     vm.expectRevert();
    //     oracle.observe(secondsAgos);
    // }

    // function test_observe_single_observation_in_past_at_exactly_seconds_ago() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     oracle.advanceTime(3);
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 3;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);
    //     assertEq(tickCumulatives[0], 0);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    // }

    // function test_observe_single_observation_in_past_counterfactual_in_past() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     oracle.advanceTime(3);
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 1;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);
    //     assertEq(tickCumulatives[0], 4);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(170141183460469231731687303715884105728));
    // }

    // function test_observe_single_observation_in_past_counterfactual_now() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: 4
    //     }));
    //     oracle.advanceTime(3);
    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 0;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);
    //     assertEq(tickCumulatives[0], 6);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(255211775190703847597530955573826158592));
    // }

    // function test_observe_singleObservation() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 2,
    //         tick: 2,
    //         liquidity: 1
    //     }));

    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 0;

    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);
    //     assertEq(tickCumulatives[0], 0);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    // }

    // function test_observe_multipleObservations() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 1,
    //         tick: 3,
    //         liquidity: 2
    //     }));
    //     oracle.grow(4);

    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 1,
    //         tick: 5,
    //         liquidity: 4
    //     }));
    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 1,
    //         tick: 7,
    //         liquidity: 6
    //     }));

    //     uint32[] memory secondsAgos = new uint32[](3);
    //     secondsAgos[0] = 0;  // current
    //     secondsAgos[1] = 1;  // 1 second ago
    //     secondsAgos[2] = 2;  // 2 seconds ago

    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);

    //     // Verify the observations
    //     assertEq(tickCumulatives.length, 3);
    //     assertEq(secondsPerLiquidityCumulativeX128s.length, 3);
    // }

    // function test_observe_fetch_multiple_observations() public {
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: 5,
    //         tick: 2,
    //         liquidity: uint128(2) ** 15
    //     }));
    //     oracle.grow(4);
    //     oracle.update(OracleTest.UpdateParams({
    //         advanceTimeBy: 13,
    //         tick: 6,
    //         liquidity: uint128(2) ** 12
    //     }));
    //     oracle.advanceTime(5);

    //     uint32[] memory secondsAgos = new uint32[](6);
    //     secondsAgos[0] = 0;
    //     secondsAgos[1] = 3;
    //     secondsAgos[2] = 8;
    //     secondsAgos[3] = 13;
    //     secondsAgos[4] = 15;
    //     secondsAgos[5] = 18;

    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);

    //     assertEq(tickCumulatives.length, 6);
    //     assertEq(tickCumulatives[0], 56);
    //     assertEq(tickCumulatives[1], 38);
    //     assertEq(tickCumulatives[2], 20);
    //     assertEq(tickCumulatives[3], 10);
    //     assertEq(tickCumulatives[4], 6);
    //     assertEq(tickCumulatives[5], 0);

    //     assertEq(secondsPerLiquidityCumulativeX128s.length, 6);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(550383467004691728624232610897330176));
    //     assertEq(secondsPerLiquidityCumulativeX128s[1], uint160(301153217795020002454768787094765568));
    //     assertEq(secondsPerLiquidityCumulativeX128s[2], uint160(103845937170696552570609926584401920));
    //     assertEq(secondsPerLiquidityCumulativeX128s[3], uint160(51922968585348276285304963292200960));
    //     assertEq(secondsPerLiquidityCumulativeX128s[4], uint160(31153781151208965771182977975320576));
    //     assertEq(secondsPerLiquidityCumulativeX128s[5], 0);
    // }

    // // Full Oracle Tests - Testing oracle at maximum capacity
    // function test_full_oracle_setup() public {
    //     // Initialize oracle
    //     oracle.initialize(OracleTest.InitializeParams({
    //         time: uint32(TEST_POOL_START_TIME),
    //         tick: 0,
    //         liquidity: 0
    //     }));

    //     // Grow oracle to max size in batches
    //     uint16 cardinalityNext = oracle.cardinalityNext();
    //     uint16 batchSize = 300;
    //     while (cardinalityNext < type(uint16).max) {
    //         uint16 growTo = uint16(min(uint256(type(uint16).max), uint256(cardinalityNext) + batchSize));
    //         oracle.grow(growTo);
    //         cardinalityNext = growTo;
    //     }

    //     // Perform batch updates
    //     for (uint256 i = 0; i < uint256(type(uint16).max); i += batchSize) {
    //         OracleTest.UpdateParams[] memory updates = new OracleTest.UpdateParams[](batchSize);
    //         for (uint256 j = 0; j < batchSize; j++) {
    //             updates[j] = OracleTest.UpdateParams({
    //                 advanceTimeBy: 13,
    //                 tick: -int24(int256(i + j)),
    //                 liquidity: uint128(i + j)
    //             });
    //         }
    //         oracle.batchUpdate(updates);
    //     }

    //     // Verify the oracle state
    //     assertEq(oracle.cardinalityNext(), type(uint16).max);
    //     assertEq(oracle.cardinality(), type(uint16).max);
    //     assertEq(oracle.index(), 165);
    // }

    // function test_full_oracle_observe_into_ordered_portion_exact() public {
    //     test_full_oracle_setup();

    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 100 * 13;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);

    //     assertEq(tickCumulatives[0], -27970560813);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(60465049086512033878831623038233202591033));
    // }

    // function test_full_oracle_observe_into_ordered_portion_unexact() public {
    //     test_full_oracle_setup();

    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 100 * 13 + 5;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);

    //     assertEq(tickCumulatives[0], -27970232823);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(60465023149565257990964350912969670793706));
    // }

    // function test_full_oracle_observe_at_latest() public {
    //     test_full_oracle_setup();

    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 0;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);

    //     assertEq(tickCumulatives[0], -28055903863);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(60471787506468701386237800669810720099776));
    // }

    // function test_full_oracle_observe_at_latest_after_time() public {
    //     test_full_oracle_setup();
    //     oracle.advanceTime(5);

    //     uint32[] memory secondsAgos = new uint32[](1);
    //     secondsAgos[0] = 5;
    //     (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(secondsAgos);

    //     assertEq(tickCumulatives[0], -28055903863);
    //     assertEq(secondsPerLiquidityCumulativeX128s[0], uint160(60471787506468701386237800669810720099776));
    // }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
