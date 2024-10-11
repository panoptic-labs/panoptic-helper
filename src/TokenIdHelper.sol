// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.24;

// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Types
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";

/// @title Deployable contract to interact with TokenIds, that comes with extra utils for ease of use
contract TokenIdHelper {
    /*//////////////////////////////////////////////////////////////
                    Expose the constants:
    //////////////////////////////////////////////////////////////*/

    /// @notice Getter method for LONG_MASK constant.
    /// @return The value of LONG_MASK.
    function LONG_MASK() external pure returns (uint256) {
        return 0x100_000000000100_000000000100_000000000100_0000000000000000;
    }

    /// @notice Getter method for CLEAR_POOLID_MASK constant.
    /// @return The value of CLEAR_POOLID_MASK.
    function CLEAR_POOLID_MASK() external pure returns (uint256) {
        return 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF_0000000000000000;
    }

    /// @notice Getter method for OPTION_RATIO_MASK constant.
    /// @return The value of OPTION_RATIO_MASK.
    function OPTION_RATIO_MASK() external pure returns (uint256) {
        return 0x0000000000FE_0000000000FE_0000000000FE_0000000000FE_0000000000000000;
    }

    /// @notice Getter method for CHUNK_MASK constant.
    /// @return The value of CHUNK_MASK.
    function CHUNK_MASK() external pure returns (uint256) {
        return 0xFFFFFFFFF200_FFFFFFFFF200_FFFFFFFFF200_FFFFFFFFF200_0000000000000000;
    }

    /// @notice Getter method for BITMASK_INT24 constant.
    /// @return The value of BITMASK_INT24.
    function BITMASK_INT24() external pure returns (int256) {
        return 0xFFFFFF;
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

    /// @notice Clear a leg in an option position with index `i`.
    /// @dev set bits of the leg to zero. Also sets the optionRatio and asset to zero of that leg.
    /// @dev NOTE: it's important that the caller fills in the leg details after.
    //  - optionRatio is zeroed
    //  - asset is zeroed
    //  - width is zeroed
    // - strike is zeroed
    //  - tokenType is zeroed
    //  - isLong is zeroed
    //  - riskPartner is zeroed
    /// @param tokenId The TokenId to clear the leg from
    /// @param i The leg index to reset, in {0,1,2,3}
    /// @return `tokenId` with the `i`th leg zeroed including optionRatio and asset
    function clearLeg(TokenId tokenId, uint256 i) external pure returns (TokenId) {
        return tokenId.clearLeg(i);
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
    ) external pure returns (TokenId overwrittenTokenId) {
        overwrittenTokenId = tokenId ^ _optionRatioMaskForLeg(legIndex);
        return overwrittenTokenId.addOptionRatio(overwrittenTokenId, newOptionRatio, legIndex);
    }

    /// @notice Helper for returning an OPTION_RATIO_MASK tailoured to the legIndex.
    /// @param legIndex The index of the leg to make a mask for (in {0,1,2,3})
    /// @return uint256 with 1s for all bits that would occupy the optionRatio of a leg within a tokenId at legIndex
    function _optionRatioMaskForLeg(uint256 legIndex) internal pure returns (uint256) {
        unchecked {
            return
                0x000000000000_000000000000_000000000000_0000000000FE_0000000000000000 <<
                (48 * legIndex);
        }
    }
}
