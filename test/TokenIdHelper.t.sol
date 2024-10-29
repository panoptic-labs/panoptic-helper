pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TokenId} from "@types/TokenId.sol";
import {TokenIdHelper} from "../src/TokenIdHelper.sol";
import {Constants} from "@libraries/Constants.sol";

contract TokenIdHelperTest is Test {
    TokenIdHelper public tokenIdHelper;

    function setUp() public {
        tokenIdHelper = new TokenIdHelper();
    }

    // TODO: make a fuzzed unwrapTokenId test
    uint64 constant $poolId = 1234;
    uint256 constant $optionRatio = 2;
    uint256 constant $asset = 1;
    uint256 constant $isLong = 1;
    uint256 constant $tokenType = 0;
    uint256 constant $riskPartner = 0;
    int24 constant $strike = 100;
    int24 constant $width = 10;
    address constant $mockPool = address(0x123);

    function test_unwrapTokenId_getsCorrectLegData() public {
        TokenIdHelper.Leg[] memory legs;

        {
            TokenId tokenId = TokenId.wrap(0).addPoolId($poolId).addLeg(
                0,
                $optionRatio,
                $asset,
                $isLong,
                $tokenType,
                $riskPartner,
                $strike,
                $width
            );

            legs = tokenIdHelper.unwrapTokenId(tokenId, $mockPool);
        }

        // Verify all leg data is preserved
        assertEq(legs.length, 1, "Should have one leg");
        assertEq(legs[0].poolId, $poolId, "Pool ID mismatch");
        assertEq(legs[0].UniswapV3Pool, $mockPool, "Pool address mismatch");
        assertEq(legs[0].optionRatio, $optionRatio, "Option ratio mismatch");
        assertEq(legs[0].asset, $asset, "Asset mismatch");
        assertEq(legs[0].isLong, $isLong, "isLong mismatch");
        assertEq(legs[0].tokenType, $tokenType, "Token type mismatch");
        assertEq(legs[0].riskPartner, $riskPartner, "Risk partner mismatch");
        assertEq(legs[0].strike, $strike, "Strike mismatch");
        assertEq(legs[0].width, $width, "Width mismatch");
    }

    // TODO:
    // - Add a version which provides a baseline test of the scaling-up-of-positionSize-case
    //   this one uses hardcoded values to ensure a scale-down scenario
    function test_equivalentPosition_preservesOriginalScale() public {
        TokenId originalPosition = TokenId
            .wrap(0)
            .addPoolId($poolId)
            .addLeg(
                0,
                2, // optionRatio = 2
                0,
                1,
                0,
                0,
                100,
                10
            )
            .addLeg(
                1,
                3, // optionRatio = 3
                0,
                1,
                0,
                0,
                100,
                10
            );
        uint128 originalSize = 1000;

        (TokenId newPosition, uint128 newSize) = tokenIdHelper.equivalentPosition(
            originalPosition,
            originalSize
        );

        uint256 originalScaleLeg0 = originalSize * originalPosition.optionRatio(0);
        uint256 newScaleLeg0 = newSize * newPosition.optionRatio(0);
        uint256 originalScaleLeg1 = originalSize * originalPosition.optionRatio(1);
        uint256 newScaleLeg1 = newSize * newPosition.optionRatio(1);

        {
            TokenIdHelper.Leg[] memory legs;
            legs = tokenIdHelper.unwrapTokenId(originalPosition, $mockPool);
        }

        {
            TokenIdHelper.Leg[] memory legs;
            legs = tokenIdHelper.unwrapTokenId(newPosition, $mockPool);
        }

        assertEq(originalScaleLeg0, newScaleLeg0, "Scale of the position not preserved on leg 0");
        assertEq(originalScaleLeg1, newScaleLeg1, "Scale of the position not preserved on leg 1");
    }

    // TODO: Make this fuzz the number of legs too
    /// Must limit the gas on this test, as it involves a factorisation helper

    /// @custom:fuzz-runs 50
    /// @custom:fuzz-max-local-rejects 100
    /// @custom:fuzz-run-limit 30000000
    function testFuzz_equivalentPosition_preservesOriginalScale(
        uint128 positionSize,
        uint8 optionRatio
    ) public {
        vm.assume(
            positionSize > 0 &&
                optionRatio > 0 &&
                optionRatio < 128 &&
                type(uint256).max / positionSize > optionRatio &&
                type(uint256).max / optionRatio > positionSize
        );
        TokenId originalPosition = TokenId.wrap(0).addPoolId(1234).addLeg(
            0,
            optionRatio,
            0,
            1,
            0,
            0,
            100,
            10
        );

        (TokenId newPosition, uint128 newSize) = tokenIdHelper.equivalentPosition(
            originalPosition,
            positionSize
        );

        if (newSize > 0) {
            uint256 originalPayoff = uint256(positionSize) * optionRatio;
            uint256 newPayoff = uint256(newSize) * newPosition.optionRatio(0);
            assertEq(originalPayoff, newPayoff, "Fuzzed payoff should be preserved");
        }
    }

    function test_scaledPosition_preservesOriginalScale() public {
        TokenId originalPosition = TokenId.wrap(0).addPoolId(1234).addLeg(
            0,
            2,
            0,
            1,
            0,
            0,
            100,
            10
        );

        uint128 scaleFactor = 2;

        TokenId scaledPosition = tokenIdHelper.scaledPosition(originalPosition, scaleFactor, true);

        assertEq(
            scaledPosition.optionRatio(0),
            originalPosition.optionRatio(0) * scaleFactor,
            "Option ratio should be scaled up by factor"
        );

        assertEq(scaledPosition.poolId(), originalPosition.poolId(), "Pool ID should not change");
        assertEq(scaledPosition.strike(0), originalPosition.strike(0), "Strike should not change");
        assertEq(scaledPosition.width(0), originalPosition.width(0), "Width should not change");
        assertEq(scaledPosition.isLong(0), originalPosition.isLong(0), "isLong should not change");
        assertEq(
            scaledPosition.tokenType(0),
            originalPosition.tokenType(0),
            "Token type should not change"
        );
    }

    // TODO: Make these 2 fuzz the # of legs
    function testFuzz_scaledPosition_up_preservesOriginalScale(
        uint128 scaleFactor,
        uint8 originalOptionRatio1,
        uint8 originalOptionRatio2
    ) public {
        // Assume non-zero / non-identity values, as well as bounded values, for meaningful test
        vm.assume(originalOptionRatio1 > 0 && originalOptionRatio2 > 0);
        vm.assume(
            scaleFactor > 1 &&
                scaleFactor < type(uint128).max / originalOptionRatio1 &&
                scaleFactor < type(uint128).max / originalOptionRatio2
        );

        // Keep ratios within bounds to avoid overflow
        vm.assume(originalOptionRatio1 < 128 && originalOptionRatio2 < 128);
        vm.assume(scaleFactor * uint128(originalOptionRatio1) < 128);
        vm.assume(scaleFactor * uint128(originalOptionRatio2) < 128);

        TokenId originalPosition = TokenId
            .wrap(0)
            .addPoolId(1234)
            .addLeg(0, originalOptionRatio1, 0, 1, 0, 0, 100, 10)
            .addLeg(1, originalOptionRatio2, 0, 1, 0, 0, 100, 10);

        TokenId scaledUpPosition = tokenIdHelper.scaledPosition(
            originalPosition,
            scaleFactor,
            true
        );

        assertEq(
            scaledUpPosition.optionRatio(0),
            originalOptionRatio1 * scaleFactor,
            "First leg ratio should be scaled up correctly"
        );
        assertEq(
            scaledUpPosition.optionRatio(1),
            originalOptionRatio2 * scaleFactor,
            "Second leg ratio should be scaled up correctly"
        );
    }

    function testFuzz_scaledPosition_down_preservesOriginalScale(
        uint128 scaleFactor,
        uint8 originalOptionRatio1,
        uint8 originalOptionRatio2
    ) public {
        // Assume non-zero / non-identity values, as well as divisible values, for meaningful test
        vm.assume(
            originalOptionRatio1 > 0 &&
                originalOptionRatio1 < 128 &&
                originalOptionRatio2 > 0 &&
                originalOptionRatio2 < 128
        );
        vm.assume(
            scaleFactor > 1 &&
                scaleFactor < originalOptionRatio1 &&
                originalOptionRatio1 % scaleFactor == 0 &&
                scaleFactor < originalOptionRatio2 &&
                originalOptionRatio2 % scaleFactor == 0
        );

        TokenId originalPosition = TokenId
            .wrap(0)
            .addPoolId(1234)
            .addLeg(0, originalOptionRatio1, 0, 1, 0, 0, 100, 10)
            .addLeg(1, originalOptionRatio2, 0, 1, 0, 0, 100, 10);
        TokenId scaledDownPosition = tokenIdHelper.scaledPosition(
            originalPosition,
            scaleFactor,
            false
        );
        assertEq(
            scaledDownPosition.optionRatio(0),
            originalOptionRatio1 / scaleFactor,
            "First leg ratio should be scaled down correctly"
        );
        assertEq(
            scaledDownPosition.optionRatio(1),
            originalOptionRatio2 / scaleFactor,
            "Second leg ratio should be scaled down correctly"
        );
    }

    // TODO: test overwriteOptionRatio? It's pretty simple though..
}
