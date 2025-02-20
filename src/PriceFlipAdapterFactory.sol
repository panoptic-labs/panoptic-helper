// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";
import {PriceFlipAdapter} from "./PriceFlipAdapter.sol";

/// @title PriceFlipAdapterFactory
/// @notice Deploys wrapper contracts around IV3CompatibleOracles that flip the price and tick values from token1/token0 to token0/token1
/// @dev This is useful for working with Uniswap V4 pools where the token order (e.g. ETH/USDC) diverges from the V3 equivalent (e.g. USDC/WETH)
/// @author Axicon Labs Limited
contract PriceFlipAdapterFactory {
    /// @notice Emitted when a new PriceFlipAdapter contract is deployed.
    /// @param underlying The underlying oracle that the adapter is wrapping
    /// @param adapter The newly deployed PriceFlipAdapter contract
    event AdapterDeployed(IV3CompatibleOracle underlying, PriceFlipAdapter adapter);

    /// @notice Thrown when an attempt is made to deploy an adapter for an oracle that already has an adapter deployed.
    error AdapterAlreadyDeployed(IV3CompatibleOracle underlying);

    /// @notice Exposes the corresponding PriceFlipAdapter deployed through this contract for an IV3CompatibleOracle.
    mapping(IV3CompatibleOracle => PriceFlipAdapter) public adapterOf;

    /// @notice Deploys a new PriceFlipAdapter contract that wraps the given IV3CompatibleOracle.
    /// @param underlying The underlying oracle to operate on
    /// @return adapter The newly deployed PriceFlipAdapter contract
    function deploy(IV3CompatibleOracle underlying) external returns (PriceFlipAdapter adapter) {
        if (address(adapterOf[underlying]) != address(0)) revert AdapterAlreadyDeployed(underlying);

        adapter = new PriceFlipAdapter(underlying);
        adapterOf[underlying] = adapter;

        emit AdapterDeployed(underlying, adapter);
    }
}
