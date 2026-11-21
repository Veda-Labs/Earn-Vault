// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IVedaStackAccess } from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAuthority } from "../../../../interfaces/external/veda/IRolesAuthority.sol";

/// @title VedaAuthorityOverlay
/// @notice A read-only authority for one BoringVault's Teller, Queues and stock solvers. It allows
///         everything the vault's RolesAuthority allows, plus the Earn stack calls recorded in the
///         vault's {VedaVaultAccessRegistry}. It is the alternative to {VedaRoleGranter}: nothing ever
///         writes to the RolesAuthority.
///
/// @dev The vault's administrator points the Teller, each Queue and each stock solver at this contract
///      with one `setAuthority` call each. The BoringVault itself keeps the RolesAuthority as its
///      authority, so no new contract sits on the path to custody.
///
///      IT MUST NEVER FAIL. Once pointed here, those contracts can be repointed only through this
///      contract, so it has no owner, no storage, no upgrade, and two rules:
///      1. the RolesAuthority is asked first, and its answer is returned before the registry is read, so
///         every permission that RolesAuthority gives, including the one that repoints an authority,
///         depends on nothing new. A module that answered to some other authority before loses what
///         that one gave, so only modules already on this RolesAuthority are repointed here;
///      2. the registry is read with a raw static call, so a registry that reverts, has no code or
///         answers with anything but a well-formed `true` denies the Earn call and nothing else.
///      The RolesAuthority call can revert only as it can today, when those contracts ask it directly.
contract VedaAuthorityOverlay is IAuthority {
    /// @notice The RolesAuthority the BoringVault answers to, whose answers pass through unchanged.
    IAuthority public immutable rolesAuthority;
    /// @notice The record of this vault's Earn engines, forwarding solvers and honored exit rails.
    IVedaStackAccess public immutable registry;

    error InvalidOverlayWiring(address account);
    error ZeroAddress();

    constructor(IAuthority rolesAuthority_, IVedaStackAccess registry_) {
        if (address(rolesAuthority_) == address(0) || address(registry_) == address(0)) revert ZeroAddress();
        if (address(rolesAuthority_).code.length == 0) revert InvalidOverlayWiring(address(rolesAuthority_));
        if (address(registry_).code.length == 0) revert InvalidOverlayWiring(address(registry_));
        rolesAuthority = rolesAuthority_;
        registry = registry_;
    }

    /// @notice Whether `user` may call `functionSig` on `target`.
    function canCall(address user, address target, bytes4 functionSig) external view returns (bool) {
        // 1. Everything allowed today stays allowed, decided before the registry is read.
        if (rolesAuthority.canCall(user, target, functionSig)) return true;
        // 2. Recorded engines and forwarding solvers get their fixed calls. The registry is read with a raw
        //    call so that a revert, missing code or malformed answer denies them instead of reverting here.
        (bool success, bytes memory result) =
            address(registry).staticcall(abi.encodeCall(IVedaStackAccess.canStackCall, (user, target, functionSig)));
        return success && result.length == 32 && abi.decode(result, (uint256)) == 1;
    }
}
