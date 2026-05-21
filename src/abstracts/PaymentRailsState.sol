// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title PaymentRailsState
/// @notice Abstract contract for managing PaymentRails state variables
/// @dev Separates state management from business logic following the Sablier pattern
/// @dev All state-modifying functions are internal, must be called by inheriting contracts
abstract contract PaymentRailsState {
    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Maps token addresses to their action configurations
    /// @dev Configuration includes action type, module address, parameters, and execution metadata
    mapping(address token => DataTypes.TokenConfig config) internal _tokenConfigs;
}
