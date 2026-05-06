// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

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

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL GETTERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Retrieves the full configuration for a specific token
    /// @dev Returns the complete TokenConfig struct from storage
    /// @param token The token address to query
    /// @return config The token's complete configuration
    function _getTokenConfig(address token) internal view returns (DataTypes.TokenConfig memory config) {
        return _tokenConfigs[token];
    }

    /// @notice Checks if a token has been configured with an action
    /// @dev A token is considered configured if its actionType is not empty
    /// @param token The token address to check
    /// @return True if token has an action configured, false otherwise
    function _isTokenConfigured(address token) internal view returns (bool) {
        return bytes(_tokenConfigs[token].actionType).length > 0;
    }

    /// @notice Checks if a token's action is currently enabled
    /// @dev Returns false if token is not configured
    /// @param token The token address to check
    /// @return True if token is configured and enabled, false otherwise
    function _isTokenEnabled(address token) internal view returns (bool) {
        return _isTokenConfigured(token) && _tokenConfigs[token].enabled;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL STATE MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Stores a complete token configuration
    /// @dev Overwrites any existing configuration for the token
    /// @param token The token address to configure
    /// @param config The complete configuration to store
    function _setTokenConfig(address token, DataTypes.TokenConfig memory config) internal {
        _tokenConfigs[token] = config;
    }

    /// @notice Deletes a token's configuration
    /// @dev Sets all fields to default values
    /// @param token The token address to clear
    function _deleteTokenConfig(address token) internal {
        delete _tokenConfigs[token];
    }
}
