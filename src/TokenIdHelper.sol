// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.24;

// Interfaces
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PeripheryErrors} from "@helper/PeripheryErrors.sol";
// Types
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";

/// @title Deployable contract to interact with TokenIds, that comes with extra utils for ease of use
contract TokenIdHelper {
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

    /// @notice The SemiFungiblePositionManager of the Panoptic instance this TokenIdHelper is intended for.
    SemiFungiblePositionManager internal immutable SFPM;
    /// @notice The maximum quantity of a given Panoptic position one may hold.
    uint128 public constant MAX_POSITION_SIZE = type(uint128).max;
    /// @notice The maximum option ratio of a leg of a Panoptic position.
    uint256 public constant MAX_OPTION_RATIO = 127;

    /// @notice Construct the TokenIdHelper contract
    /// @param _SFPM address of the SemiFungiblePositionManager
    /// @dev the SFPM is used to get the pool ID for a given address
    constructor(SemiFungiblePositionManager _SFPM) payable {
        SFPM = _SFPM;
    }

    /*//////////////////////////////////////////////////////////////
                      Expose the decoding methods:
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the full poolId for the provided TokenId.
    /// @param tokenId The TokenId to extract `poolId` from.
    /// @return The `poolId` (Panoptic's pool fingerprint, contains the whole 64-bit sequence with the tickSpacing) of the Uniswap V3 pool.
    function poolId(TokenId tokenId) external pure returns (uint64) {
        return tokenId.poolId();
    }

    /// @notice The tickSpacing of this option position.
    /// @param tokenId The TokenId to extract `tickSpacing` from
    /// @return The `tickSpacing` of the Uniswap v3 pool
    function tickSpacing(TokenId tokenId) external pure returns (int24) {
        return tokenId.tickSpacing();
    }

    /// @notice Get the asset basis for this TokenId.
    /// @param tokenId The TokenId to extract `asset` from
    /// @param legIndex The leg index of this position (in {0,1,2,3}) to extract `asset` from
    /// @dev Occupies the leftmost bit of the optionRatio 4 bits slot.
    /// @return 0 if asset is token0, 1 if asset is token1
    function asset(TokenId tokenId, uint256 legIndex) external pure returns (uint256) {
        return tokenId.asset(legIndex);
    }

    /// @notice Get the number of contracts multiplier for leg `legIndex`.
    /// @param tokenId The TokenId to extract `optionRatio` at `legIndex` from
    /// @param legIndex The leg index of this position (in {0,1,2,3})
    /// @return The number of contracts multiplier for leg `legIndex`
    function optionRatio(TokenId tokenId, uint256 legIndex) external pure returns (uint256) {
        return tokenId.optionRatio(legIndex);
    }

    /// @notice Return 1 if the nth leg (leg index `legIndex`) is a long position.
    /// @param tokenId The TokenId to extract `isLong` at `legIndex` from
    /// @param legIndex The leg index of this position (in {0,1,2,3})
    /// @return 1 if long; 0 if not long
    function isLong(TokenId tokenId, uint256 legIndex) external pure returns (uint256) {
        return tokenId.isLong(legIndex);
    }

    /// @notice Get the type of token moved for a given leg (implies a call or put). Either Token0 or Token1.
    /// @param tokenId The TokenId to extract `tokenType` at `legIndex` from
    /// @param legIndex The leg index of this position (in {0,1,2,3})
    /// @return 1 if the token moved is token1 or 0 if the token moved is token0
    function tokenType(TokenId tokenId, uint256 legIndex) external pure returns (uint256) {
        return tokenId.tokenType(legIndex);
    }

    /// @notice Get the associated risk partner of the leg index (generally another leg index in the position if enabled or the same leg index if no partner).
    /// @param tokenId The TokenId to extract `riskPartner` at `legIndex` from
    /// @param legIndex The leg index of this position (in {0,1,2,3})
    /// @return The leg index of `legIndex`'s risk partner
    function riskPartner(TokenId tokenId, uint256 legIndex) external pure returns (uint256) {
        return tokenId.riskPartner(legIndex);
    }

    /// @notice Get the strike price tick of the nth leg (with index `legIndex`).
    /// @param tokenId The TokenId to extract `strike` at `legIndex` from
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return The strike price (the underlying price of the leg)
    function strike(TokenId tokenId, uint256 legIndex) external pure returns (int24) {
        return tokenId.strike(legIndex);
    }

    /// @notice Get the width of the nth leg (index `legIndex`). This is half the tick-range covered by the leg (tickUpper - tickLower)/2.
    /// @dev Return as int24 to be compatible with the strike tick format (they naturally go together).
    /// @param tokenId The TokenId to extract `width` at `legIndex` from
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return The width of the position
    function width(TokenId tokenId, uint256 legIndex) external pure returns (int24) {
        return tokenId.width(legIndex);
    }

    /*//////////////////////////////////////////////////////////////
                     Expose the encoding methods:
    //////////////////////////////////////////////////////////////*/

    /// @notice Add the Uniswap V3 Pool pointed to by this option position (contains the entropy and tickSpacing).
    /// @param tokenId The TokenId to add `_poolId` to
    /// @param _poolId The PoolID to add to `tokenId`
    /// @return `tokenId` with `_poolId` added to the PoolID slot
    function addPoolId(TokenId tokenId, uint64 _poolId) external pure returns (TokenId) {
        return tokenId.addPoolId(_poolId);
    }

    /// @notice Add the `tickSpacing` to the PoolID for `tokenId`.
    /// @param tokenId The TokenId to add `_tickSpacing` to
    /// @param _tickSpacing The tickSpacing to add to `tokenId`
    /// @return `tokenId` with `_tickSpacing` added to the TickSpacing slot in the PoolID
    function addTickSpacing(TokenId tokenId, int24 _tickSpacing) external pure returns (TokenId) {
        return tokenId.addTickSpacing(_tickSpacing);
    }

    /// @notice Add the asset basis for this position.
    /// @param tokenId The TokenId to add `_asset` to
    /// @param _asset The asset to add to the Asset slot in `tokenId` for `legIndex`
    /// @param legIndex The leg index of this position (in {0,1,2,3})
    /// @dev Occupies the leftmost bit of the optionRatio 4 bits slot
    /// @return `tokenId` with `_asset` added to the Asset slot
    function addAsset(
        TokenId tokenId,
        uint256 _asset,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addAsset(_asset, legIndex);
    }

    /// @notice Add the number of contracts multiplier to leg index `legIndex`.
    /// @param tokenId The TokenId to add `_optionRatio` to
    /// @param _optionRatio The number of contracts multiplier to add to the OptionRatio slot in `tokenId` for LegIndex
    /// @param legIndex The leg index of the position (in {0,1,2,3})
    /// @return `tokenId` with `_optionRatio` added to the OptionRatio slot for `legIndex`
    function addOptionRatio(
        TokenId tokenId,
        uint256 _optionRatio,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addOptionRatio(_optionRatio, legIndex);
    }

    /// @notice Add "isLong" parameter indicating whether a leg is long (isLong=1) or short (isLong=0).
    /// @notice returns 1 if the nth leg (leg index n-1) is a long position.
    /// @param tokenId The TokenId to add `_isLong` to
    /// @param _isLong The isLong parameter to add to the IsLong slot in `tokenId` for `legIndex`
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return `tokenId` with `_isLong` added to the IsLong slot for `legIndex`
    function addIsLong(
        TokenId tokenId,
        uint256 _isLong,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addIsLong(_isLong, legIndex);
    }

    /// @notice Add the type of token moved for a given leg (implies a call or put). Either Token0 or Token1.
    /// @param tokenId The TokenId to add `_tokenType` to
    /// @param _tokenType The tokenType to add to the TokenType slot in `tokenId` for `legIndex`
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return `tokenId` with `_tokenType` added to the TokenType slot for `legIndex`
    function addTokenType(
        TokenId tokenId,
        uint256 _tokenType,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addTokenType(_tokenType, legIndex);
    }

    /// @notice Add the associated risk partner of the leg index (generally another leg in the overall position).
    /// @param tokenId The TokenId to add `_riskPartner` to
    /// @param _riskPartner The riskPartner to add to the RiskPartner slot in `tokenId` for `legIndex`
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return `tokenId` with `_riskPartner` added to the RiskPartner slot for `legIndex`
    function addRiskPartner(
        TokenId tokenId,
        uint256 _riskPartner,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addRiskPartner(_riskPartner, legIndex);
    }

    /// @notice Add the strike price tick of the nth leg (index `legIndex`).
    /// @param tokenId The TokenId to add `_strike` to
    /// @param _strike The strike price tick to add to the Strike slot in `tokenId` for `legIndex`
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return `tokenId` with `_strike` added to the Strike slot for `legIndex`
    function addStrike(
        TokenId tokenId,
        int24 _strike,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addStrike(_strike, legIndex);
    }

    /// @notice Add the width of the nth leg (index `legIndex`).
    /// @param tokenId The TokenId to add `_width` to
    /// @param _width The width to add to the Width slot in `tokenId` for `legIndex`
    /// @param legIndex the leg index of this position (in {0,1,2,3})
    /// @return `tokenId` with `_width` added to the Width slot for `legIndex`
    function addWidth(
        TokenId tokenId,
        int24 _width,
        uint256 legIndex
    ) external pure returns (TokenId) {
        return tokenId.addWidth(_width, legIndex);
    }

    /// @notice Add a leg to a TokenId.
    /// @param tokenId The tokenId in the SFPM representing an option position
    /// @param legIndex The leg index of this position (in {0,1,2,3}) to add
    /// @param _optionRatio The relative size of the leg
    /// @param _asset The asset of the leg
    /// @param _isLong Whether the leg is long
    /// @param _tokenType The type of token moved for the leg
    /// @param _riskPartner The associated risk partner of the leg
    /// @param _strike The strike price tick of the leg
    /// @param _width The width of the leg
    /// @return tokenId The tokenId with the leg added
    function addLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 _optionRatio,
        uint256 _asset,
        uint256 _isLong,
        uint256 _tokenType,
        uint256 _riskPartner,
        int24 _strike,
        int24 _width
    ) external pure returns (TokenId) {
        tokenId = tokenId.addOptionRatio(_optionRatio, legIndex);
        tokenId = tokenId.addAsset(_asset, legIndex);
        tokenId = tokenId.addIsLong(_isLong, legIndex);
        tokenId = tokenId.addTokenType(_tokenType, legIndex);
        tokenId = tokenId.addRiskPartner(_riskPartner, legIndex);
        tokenId = tokenId.addStrike(_strike, legIndex);
        return tokenId.addWidth(_width, legIndex);
    }

    /*//////////////////////////////////////////////////////////////
                Expose original helpers from the library:
    //////////////////////////////////////////////////////////////*/

    /// @notice Flip all the `isLong` positions in the legs in the `tokenId` option position.
    /// @dev Uses XOR on existing isLong bits.
    /// @dev Useful when we need to take an existing tokenId but now burn it.
    /// @dev The way to do this is to simply flip it to a short instead.
    /// @param tokenId The TokenId to flip isLong for on all active legs
    /// @return tokenId with all `isLong` bits flipped
    function flipToBurnToken(TokenId tokenId) external pure returns (TokenId) {
        return tokenId.flipToBurnToken();
    }

    /// @notice Get the number of longs in this option position.
    /// @notice Count the number of legs (out of a maximum of 4) that are long positions.
    /// @param tokenId The TokenId to count longs for
    /// @return The number of long positions in `tokenId` (in the range {0,...,4})
    function countLongs(TokenId tokenId) external pure returns (uint256) {
        return tokenId.countLongs();
    }

    /// @notice Get the option position's nth leg's (index `legIndex`) tick ranges (lower, upper).
    /// @dev NOTE: Does not extract liquidity which is the third piece of information in a LiquidityChunk.
    /// @param tokenId The TokenId to extract the tick range from
    /// @param legIndex The leg index of the position (in {0,1,2,3})
    /// @return legLowerTick The lower tick of the leg/liquidity chunk
    /// @return legUpperTick The upper tick of the leg/liquidity chunk
    function asTicks(
        TokenId tokenId,
        uint256 legIndex
    ) external pure returns (int24 legLowerTick, int24 legUpperTick) {
        return tokenId.asTicks(legIndex);
    }

    /// @notice Return the number of active legs in the option position.
    /// @param tokenId The TokenId to count active legs for
    /// @dev ASSUMPTION: There is at least 1 leg in this option position.
    /// @dev ASSUMPTION: For any leg, the option ratio is always > 0 (the leg always has a number of contracts associated with it).
    /// @return The number of active legs in `tokenId` (in the range {0,...,4})
    function countLegs(TokenId tokenId) external pure returns (uint256) {
        return tokenId.countLegs();
    }

    /// @notice Clear a leg in an option position with index `legIndex`.
    /// @dev set bits of the leg to zero. Also sets the optionRatio and asset to zero of that leg.
    /// @dev NOTE: it's important that the caller fills in the leg details after.
    //  - optionRatio is zeroed
    //  - asset is zeroed
    //  - width is zeroed
    //  - strike is zeroed
    //  - tokenType is zeroed
    //  - isLong is zeroed
    //  - riskPartner is zeroed
    /// @param tokenId The TokenId to clear the leg from
    /// @param legIndex The leg index to reset, in {0,1,2,3}
    /// @return `tokenId` with the `i`th leg zeroed including optionRatio and asset
    function clearLeg(TokenId tokenId, uint256 legIndex) external pure returns (TokenId) {
        return tokenId.clearLeg(legIndex);
    }

    /*//////////////////////////////////////////////////////////////
                     Expose the validation methods:
    //////////////////////////////////////////////////////////////*/

    /// @notice Validate an option position and all its active legs; return the underlying AMM address.
    /// @dev Used to validate a position tokenId and its legs.
    /// @param tokenId The TokenId to validate
    function validate(TokenId tokenId) external pure {
        return tokenId.validate();
    }

    /// @notice Validate that a position `tokenId` and its legs/chunks are exercisable.
    /// @dev At least one long leg must be far-out-of-the-money (i.e. price is outside its range).
    /// @dev Reverts if the position is not exercisable.
    /// @param tokenId The TokenId to validate for exercisability
    /// @param currentTick The current tick corresponding to the current price in the Univ3 pool
    function validateIsExercisable(TokenId tokenId, int24 currentTick) external pure {
        return tokenId.validateIsExercisable(currentTick);
    }

    /*//////////////////////////////////////////////////////////////
                    New utils for editing tokenIds:
    //////////////////////////////////////////////////////////////*/

    /// @notice Overwrite the option ratio of a specific leg in a TokenId
    /// @param tokenId The TokenId on which the caller wishes to overwrite an optionRatio
    /// @param newOptionRatio The number of contracts multiplier to add to the OptionRatio slot in `tokenId` for `legIndex`
    /// @param legIndex The index of the position's leg for which we wish to alter optionRatio (in {0,1,2,3})
    /// @return overwrittenTokenId `tokenId` with `newOptionRatio` written to the OptionRatio slot for `legIndex`
    function overwriteOptionRatio(
        TokenId tokenId,
        uint256 newOptionRatio,
        uint256 legIndex
    ) public pure returns (TokenId overwrittenTokenId) {
        unchecked {
            overwrittenTokenId = TokenId.wrap(
                TokenId.unwrap(tokenId) &
                    ~(// Get a uint with bits set to 1 for the bits of the `legIndex`th leg that would occupy the optionRatio
                    0x000000000000_000000000000_000000000000_0000000000FE_0000000000000000 <<
                        (48 * legIndex))
            );
        }

        return overwrittenTokenId.addOptionRatio(newOptionRatio, legIndex);
    }

    /// @notice Generate a tokenID and positionSize that represents the same position as the supplied
    /// tokenID and positionSize, but with the optionRatios of each leg scaled upward/downward
    /// (and positionSize scaled inversely).
    /// @dev This is useful if you want to effectively hold the same position but need to avoid minting
    /// the same tokenID twice in a row.
    /// @param oldPosition The original TokenId
    /// @param oldPositionSize The original position size
    /// @return newPosition The new TokenId with adjusted optionRatios
    /// @return newPositionSize The new position size, inversely scaled to the optionRatio changes. 0 if no valid alteration found
    function equivalentPosition(
        TokenId oldPosition,
        uint128 oldPositionSize
    ) external view returns (TokenId newPosition, uint128 newPositionSize) {
        uint256[] memory optionRatios = new uint256[](oldPosition.countLegs());
        for (uint256 i = 0; i < optionRatios.length; i++) {
            optionRatios[i] = oldPosition.optionRatio(i);
        }

        newPosition = oldPosition;

        // First strategy:
        // - Divide the position size by its lowest non-identity factor,
        // - and then multiply all the leg's option ratios by it
        // (if doing so results in a valid option ratio for each leg)
        bool scalingUpwardFailed = false;
        if (oldPositionSize > 1) {
            uint256 lowestOldPositionSizeFactor = _lowestNonIdentityFactor(oldPositionSize);
            for (uint256 i = 0; i < optionRatios.length; i++) {
                if (
                    // break early if lowestOldPositionSizeFactor * optionsRatios[i] overflows:
                    lowestOldPositionSizeFactor > type(uint256).max / optionRatios[i] ||
                    // or if it exceeds the max option ratio:
                    lowestOldPositionSizeFactor * optionRatios[i] > MAX_OPTION_RATIO
                ) {
                    scalingUpwardFailed = true;
                    break;
                } else {
                    newPosition = overwriteOptionRatio(
                        newPosition,
                        lowestOldPositionSizeFactor * optionRatios[i],
                        i
                    );
                }
            }

            if (!scalingUpwardFailed) {
                return (
                    newPosition,
                    // oldPositionSize was originally a uint128, and the factor is guaranteed to be <=
                    oldPositionSize / uint128(lowestOldPositionSizeFactor)
                );
            }
        }

        // Second strategy: Find the smallest non-identity common factor among the oldPosition's leg's optionRatios. if there is one:
        // - divide all of the option ratios by it
        // - return newPosition = oldPosition * LCD _if_ that value is less than max position size
        uint256 lcdAmongOptionRatios = _findLeastCommonDivisor(optionRatios);
        if (
            lcdAmongOptionRatios > 1 &&
            (// can oldPositionSize be multiplied by lcdAmongOptionRatios, w/o overflowing, and stay below MAX_POSITION_SIZE?
            oldPositionSize < type(uint128).max / uint128(lcdAmongOptionRatios) &&
                oldPositionSize * uint128(lcdAmongOptionRatios) < MAX_POSITION_SIZE)
        ) {
            for (uint256 i = 0; i < optionRatios.length; i++) {
                newPosition = overwriteOptionRatio(
                    newPosition,
                    optionRatios[i] / lcdAmongOptionRatios,
                    i
                );
            }
            newPositionSize = oldPositionSize * uint128(lcdAmongOptionRatios);
        }

        // If neither of these work, return newPositionSize = 0:
    }

    /// @notice Finds the smallest factor of a number.
    /// @dev Iterates from 2 up to n to find the first number that divides n without remainder.
    /// @param n The number to find the lowest factor for
    /// @return The smallest number > 1 that divides n evenly, or n itself if n is prime
    function _lowestNonIdentityFactor(uint256 n) internal pure returns (uint256) {
        for (uint256 i = 2; i <= n; i++) if (n % i == 0) return i;
    }

    /// @notice Finds the smallest number that divides all numbers in the input array.
    /// @dev First finds minimum value in array to optimize search space, then checks each potential
    /// divisor against all numbers. Returns 1 if no common divisor is found.
    /// @param numbers Array of numbers to find common divisor for
    /// @return Smallest positive integer that divides all numbers in the array
    function _findLeastCommonDivisor(uint256[] memory numbers) internal pure returns (uint256) {
        uint256 min = numbers[0];
        for (uint256 i = 1; i < numbers.length; i++) {
            if (numbers[i] < min) {
                min = numbers[i];
            }
        }

        for (uint256 i = 2; i <= min; i++) {
            bool isDivisor = true;
            for (uint256 j = 0; j < numbers.length; j++) {
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

    /// @notice Generate a tokenID that represents the same position as the supplied tokenID, but
    /// with the optionRatios of each leg scaled upward/downward.
    /// @dev This is useful if you want to effectively hold the same position but need to avoid
    /// minting the same tokenID twice in a row.
    /// @param oldPosition The original TokenId
    /// @param scaleFactor The factor to scale up/down by
    /// @param scalingUp Whether we're increasing or decreasing each leg.optionRatio
    /// @return newPosition The new TokenId with adjusted optionRatios
    function scaledPosition(
        TokenId oldPosition,
        uint128 scaleFactor,
        bool scalingUp
    ) external view returns (TokenId newPosition) {
        uint256[] memory optionRatios = new uint256[](oldPosition.countLegs());
        for (uint256 i = 0; i < optionRatios.length; i++) {
            optionRatios[i] = oldPosition.optionRatio(i);
        }

        newPosition = oldPosition;

        for (uint256 i = 0; i < optionRatios.length; i++) {
            if (
                scalingUp
                    ? scaleFactor * optionRatios[i] < MAX_OPTION_RATIO
                    : optionRatios[i] / scaleFactor > 0
            ) {
                newPosition = overwriteOptionRatio(
                    newPosition,
                    scalingUp ? scaleFactor * optionRatios[i] : optionRatios[i] / scaleFactor,
                    i
                );
            } else {
                revert PeripheryErrors.InvalidScaleFactor();
            }
        }
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
                (, uint256 required0) = PanopticMath.getCrossBalances(
                    tokenData0,
                    tokenData1,
                    Math.getSqrtRatioAtTick(atTick)
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

    /// @notice Unwraps the contents of the tokenId into its legs.
    /// @param tokenId the input tokenId
    /// @return legs an array of leg structs
    function unwrapTokenId(TokenId tokenId) public view returns (Leg[] memory) {
        uint256 numLegs = tokenId.countLegs();
        Leg[] memory legs = new Leg[](numLegs);

        uint64 _poolId = tokenId.poolId();
        address UniswapV3Pool = address(SFPM.getUniswapV3PoolFromId(tokenId.poolId()));
        for (uint256 i = 0; i < numLegs; ++i) {
            legs[i].poolId = _poolId;
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
}
