// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.18;

// Base
import {Multicall} from "./base/Multicall.sol";
import {SelfPermit} from "v3-periphery/base/SelfPermit.sol";
// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
/// Libraries
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {PeripheryErrors} from "@helper/PeripheryErrors.sol";

/// @title Facilitates the migration from Uniswap LPing to PLPing.
/// @author Axicon Labs Limited
contract UniswapMigrator is Multicall, SelfPermit {
    /// @notice Canonical NonFungiblePositionManager deployment
    INonfungiblePositionManager immutable NFPM;

    /// @notice Canonical Uniswap V4 PositionManager deployment
    IPositionManager immutable V4_PM;

    /// @notice Canonical WETH deployment
    IWETH9 immutable WETH;

    /// @notice Set canonical deployments of NonFungiblePositionManager and Uniswap V4 PositionManager.
    /// @param _NFPM Address of canonical NonFungiblePositionManager
    /// @param _V4_PM Address of canonical Uniswap V4 PositionManager
    /// @param _WETH Address of canonical WETH contract
    constructor(INonfungiblePositionManager _NFPM, IPositionManager _V4_PM, IWETH9 _WETH) {
        NFPM = _NFPM;
        V4_PM = _V4_PM;
        WETH = _WETH;
    }

    /// @notice Removes all liquidity from `tokenId` in the NFPM and deposits into supplied `CollateralTracker` vaults.
    /// @param tokenId The NFPM token ID to migrate
    /// @param amount0Min The minimum amount of token0 that should be collected from `tokenId`
    /// @param amount1Min The minimum amount of token1 that should be collected from `tokenId`
    /// @param unwrapWETH If true, assume `token0` or `token1` is WETH and `ct0` is native ETH, unwrapping received WETH to deposit in `ct0`
    /// @param swapAddresses If applicable, a list of addresses to call in order to swap tokens to the desired deposit ratio
    /// @param swapCalls List of calls to make, corresponding to `swapAddresses`, in order to swap tokens
    /// @param ct0 Desired collateral vault to deposit token0 into
    /// @param ct1 Desired collateral vault to deposit token1 into
    function migrateV3(
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min,
        bool unwrapWETH,
        address[] memory swapAddresses,
        bytes[] memory swapCalls,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external {
        if (NFPM.ownerOf(tokenId) != msg.sender) revert PeripheryErrors.UnauthorizedMigration();

        (, , address token0, address token1, , , , uint128 liquidity, , , , ) = NFPM.positions(
            tokenId
        );

        NFPM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: type(uint32).max
            })
        );

        NFPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        for (uint256 i = 0; i < swapAddresses.length; i++) {
            if (swapAddresses[i] == address(NFPM) || swapAddresses[i] == address(V4_PM))
                revert PeripheryErrors.InvalidSwapAddress();

            (bool success, bytes memory result) = swapAddresses[i].call(swapCalls[i]);
            if (!success) {
                // Bubble up the revert reason
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }

        // swap v3 WETH/TOKEN order to match alphanumeric order in v4 (0x0000..., TOKEN)
        if (unwrapWETH && token1 == address(WETH)) (token0, token1) = (token1, token0);

        uint256 amountCollected = IERC20Partial(token0).balanceOf(address(this));
        if (amountCollected > 0) {
            if (unwrapWETH) {
                WETH.withdraw(amountCollected);
                ct0.deposit{value: amountCollected}(amountCollected, msg.sender);
            } else {
                IERC20Partial(token0).approve(address(ct0), amountCollected);
                ct0.deposit(amountCollected, msg.sender);
            }
        }

        amountCollected = IERC20Partial(token1).balanceOf(address(this));
        if (amountCollected > 0) {
            IERC20Partial(token1).approve(address(ct1), amountCollected);
            ct1.deposit(amountCollected, msg.sender);
        }
    }

    /// @notice Removes all liquidity from `tokenId` in the V4 position manager and deposits into supplied `CollateralTracker` vaults.
    /// @param tokenId The V4 position manager token ID to migrate
    /// @param amount0Min The minimum amount of token0 that should be collected from `tokenId`
    /// @param amount1Min The minimum amount of token1 that should be collected from `tokenId`
    /// @param swapAddresses If applicable, a list of addresses to call in order to swap tokens to the desired deposit ratio
    /// @param swapCalls List of calls to make, corresponding to `swapAddresses`, in order to swap tokens
    /// @param swapValues List of ether values to send with the corresponding swap call
    /// @param ct0 Desired collateral vault to deposit token0 into
    /// @param ct1 Desired collateral vault to deposit token1 into
    /// @param hookData Data to be passed to a potential Uniswap hook when liquidity is burned
    function migrateV4(
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min,
        address[] memory swapAddresses,
        bytes[] memory swapCalls,
        uint256[] memory swapValues,
        CollateralTracker ct0,
        CollateralTracker ct1,
        bytes memory hookData
    ) external {
        if (IERC721(address(V4_PM)).ownerOf(tokenId) != msg.sender)
            revert PeripheryErrors.UnauthorizedMigration();

        address token0 = ct0.asset();
        address token1 = ct1.asset();

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(token0, token1, address(this));

        V4_PM.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)),
                params
            ),
            block.timestamp
        );

        for (uint256 i = 0; i < swapAddresses.length; i++) {
            if (swapAddresses[i] == address(NFPM) || swapAddresses[i] == address(V4_PM))
                revert PeripheryErrors.InvalidSwapAddress();
            (bool success, bytes memory result) = swapAddresses[i].call{value: swapValues[i]}(
                swapCalls[i]
            );
            if (!success) {
                // Bubble up the revert reason
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }

        // Tokens are sorted alphanumerically, so native ETH is always token0
        if (token0 == address(0)) {
            if (address(this).balance > 0)
                ct0.deposit{value: address(this).balance}(address(this).balance, msg.sender);
        } else {
            uint256 amount0Collected = IERC20Partial(token0).balanceOf(address(this));
            if (amount0Collected > 0) {
                if (token0 != address(0))
                    IERC20Partial(ct0.asset()).approve(address(ct0), amount0Collected);
                ct0.deposit(amount0Collected, msg.sender);
            }
        }

        uint256 amount1Collected = IERC20Partial(token1).balanceOf(address(this));
        if (amount1Collected > 0) {
            IERC20Partial(ct1.asset()).approve(address(ct1), amount1Collected);
            ct1.deposit(amount1Collected, msg.sender);
        }
    }

    /// @notice Accepts native currency.
    /// @dev Used to handle native currency in migrateV4 for native-currency-based pools + receive native currency from mid-migration swaps and WETH unwraps.
    receive() external payable {}
}
