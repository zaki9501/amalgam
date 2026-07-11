// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IHookRegistry {
    /**
     * @dev Updates the allowed status of a hook.
     * @notice This function is restricted to the owner of the contract.
     * @param hook The address of the hook to be updated.
     * @param allowed A boolean value indicating whether the hook should be allowed (true) or disallowed (false).
     * @dev Emits no events.
     */
    function updateHook(address hook, bool allowed) external;

    /**
     * @dev Checks if a hook is allowed.
     * @param hook The address of the hook to check.
     * @return A boolean value indicating whether the hook is allowed (true) or disallowed (false).
     * @dev This function is a view function and does not alter state.
     */
    function isHookAllowed(
        address hook
    ) external view returns (bool);
}
