// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title NodeState
/// @notice Abstract contract for managing Node state variables
/// @dev Separates state management from business logic following the Sablier pattern
/// @dev All state-modifying functions are internal, must be called by inheriting contracts
abstract contract NodeState {
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

    /// @notice Gets the timestamp of the last execution for a token
    /// @dev Returns 0 if never executed
    /// @param token The token address to query
    /// @return Timestamp of last execution, or 0 if never executed
    function _getLastExecuted(address token) internal view returns (uint256) {
        return _tokenConfigs[token].lastExecuted;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL STATE MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Updates the last execution timestamp for a token
    /// @dev Should be called after successful action execution
    /// @param token The token address to update
    /// @param timestamp The execution timestamp (typically block.timestamp)
    function _setLastExecuted(address token, uint256 timestamp) internal {
        _tokenConfigs[token].lastExecuted = timestamp;
    }

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
