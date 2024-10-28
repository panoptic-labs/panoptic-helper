// TODO: test equivalentPosition - check that the two positions truly have the same payoff curve
// TODO: test scaledPosition - check that the two positions truly have the same payoff curve

// SPDX-License-Identifier: UNLICENSED
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

    // TODO: some day, could make these values fuzzed
    uint64 constant $poolId = 1234;
    uint256 constant $optionRatio = 2;
    uint256 constant $asset = 1;
    uint256 constant $isLong = 1;
    uint256 constant $tokenType = 0;
    uint256 constant $riskPartner = 0;
    int24 constant $strike = 100;
    int24 constant $width = 10;
    address constant $mockPool = address(0x123);

    function test_unwrapTokenId_maintainsLegData() public {
        TokenIdHelper.Leg[] memory legs;

        {
          TokenId tokenId = TokenId.wrap(0)
              .addPoolId($poolId)
              .addLeg(
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

    // TODO: why is this failing?
    function test_equivalentPosition_preservesPayoff() public {
        uint64 poolId = 1234;
        TokenId originalPosition = TokenId.wrap(0)
            .addPoolId(poolId)
            .addLeg(
                0,
                2, // optionRatio = 2
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

        uint256 originalPayoff = originalSize * originalPosition.optionRatio(0);
        uint256 newPayoff = newSize * newPosition.optionRatio(0);

        assertEq(originalPayoff, newPayoff, "Payoff should be preserved");
    }

    // TODO: this one also failing
    function test_scaledPosition_preservesPayoff() public {
        uint64 poolId = 1234;
        TokenId originalPosition = TokenId.wrap(0)
            .addPoolId(poolId)
            .addLeg(
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
        bool scalingUp = true;

        TokenId scaledPosition = tokenIdHelper.scaledPosition(
            originalPosition,
            scaleFactor,
            scalingUp
        );

        assertEq(
            scaledPosition.optionRatio(0),
            originalPosition.optionRatio(0) * scaleFactor,
            "Option ratio should be scaled up by factor"
        );

        assertEq(scaledPosition.poolId(), originalPosition.poolId(), "Pool ID should not change");
        assertEq(scaledPosition.strike(0), originalPosition.strike(0), "Strike should not change");
        assertEq(scaledPosition.width(0), originalPosition.width(0), "Width should not change");
        assertEq(scaledPosition.isLong(0), originalPosition.isLong(0), "isLong should not change");
        assertEq(scaledPosition.tokenType(0), originalPosition.tokenType(0), "Token type should not change");
    }

    // TODO: Get to these once the above work
    /*
    function testFuzz_equivalentPosition_preservesPayoff(
        uint128 positionSize,
        uint8 optionRatio
    ) public {
        vm.assume(positionSize > 0 && optionRatio > 0);
        vm.assume(optionRatio < 128); // TODO better max here?

        TokenId originalPosition = TokenId.wrap(0)
            .addPoolId(1234)
            .addLeg(
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

    function testFuzz_scaledPosition_preservesRelativeRatios( ...
    */

}
