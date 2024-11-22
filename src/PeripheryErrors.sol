// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Custom Errors library.
/// @author Axicon Labs Limited
/// @notice Contains all custom error messages used in Panoptic's periphery contracts.
library PeripheryErrors {
    /// @notice Caller does not own the NFPM token being migrated
    error UnauthorizedMigration();

    /// @notice Caller supplied a factor to scale an option ratio down by,
    /// but the ratio is not divisible by that factor
    error InvalidScaleFactor();
}
