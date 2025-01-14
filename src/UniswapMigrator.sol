// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.18;

// Base
import {Multicall} from "@base/Multicall.sol";
import {SelfPermit} from "v3-periphery/base/SelfPermit.sol";
// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
/// Libraries
import {PeripheryErrors} from "@helper/PeripheryErrors.sol";

/// @title Facilitates the migration from Uniswap LPing to PLPing.
/// @author Axicon Labs Limited
contract UniswapMigrator is Multicall, SelfPermit {
    /// @notice Canonical NonFungiblePositionManager deployment
    INonfungiblePositionManager immutable NFPM;

    /// @notice Set canonical deployment of NonFungiblePositionManager.
    /// @param _NFPM Address of canonical NonFungiblePositionManager
    constructor(INonfungiblePositionManager _NFPM) {
        NFPM = _NFPM;
    }

    /// @notice Removes all liquidity from `tokenId` in the NFPM and deposits into collateral vaults.
    /// @dev All positions in `tokenIds` SHOULD be on the same pool.
    /// @dev All positions in `tokenIds` MUST have the same token0/token1.
    /// @dev `amountMins` MUST be the same length as `tokenIds`.
    /// @param tokenId The NFPM token ID to migrate
    /// @param amount0Min The minimum amount of token0 that should be collected from the position
    /// @param amount1Min The minimum amount of token1 that should be collected from the position
    /// @param ct0 Desired collateral vault to deposit token0 into
    /// @param ct1 Desired collateral vault to deposit token1 into
    function migrate(
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external {
        if (NFPM.ownerOf(tokenId) != msg.sender) revert PeripheryErrors.UnauthorizedMigration();

        (, , , , , , , uint128 liquidity, , , , ) = NFPM.positions(tokenId);

        NFPM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: type(uint32).max
            })
        );

        (uint256 amount0Collected, uint256 amount1Collected) = NFPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (amount0Collected > 0) {
            IERC20Partial(ct0.asset()).approve(address(ct0), amount0Collected);
            ct0.deposit(amount0Collected, msg.sender);
        }

        if (amount1Collected > 0) {
            IERC20Partial(ct1.asset()).approve(address(ct1), amount1Collected);
            ct1.deposit(amount1Collected, msg.sender);
        }
    }
}
