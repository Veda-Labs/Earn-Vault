// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IAccountant } from "../../external/veda/IAccountant.sol";
import { IBoringQueue } from "../../external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../external/veda/IBoringVault.sol";
import { ITeller } from "../../external/veda/ITeller.sol";

/// @notice The Teller, optional tracking Queue with its stock solver, and Accountant that are canonical
///         for one BoringVault, published once for every Earn stack on that vault.
interface IVedaVaultRegistry {
    function vault() external view returns (IBoringVault);
    function baseAsset() external view returns (address);
    function teller() external view returns (ITeller);
    /// @notice The tracking Queue new requests use, or zero when the vault is immediate-only.
    function queue() external view returns (IBoringQueue);
    function accountant() external view returns (IAccountant);
    /// @notice The stock solver of {queue}; zero exactly when {queue} is zero.
    function solver() external view returns (IBoringSolver);
    /// @notice Publications so far. Zero means nothing has been published.
    function version() external view returns (uint64);
    /// @notice Whether `account` administers the BoringVault: its owner, or the owner of its authority.
    function isVaultAdmin(address account) external view returns (bool);
}

/// @notice The seam through which a {VedaStackFactory} authorizes the engines and forwarding solvers it
///         builds. `VedaRoleGranter` implements it with RolesAuthority roles, and
///         `VedaVaultAccessRegistry` with a record that `VedaAuthorityOverlay` reads.
interface IVedaStackAuthorizer {
    /// @notice Whether the vault's administrator has named `factory` as a caller the authorizer accepts.
    function isFactory(address factory) external view returns (bool);
    function setEngineAuthorized(address engine, bool authorized) external;
    function setForwarderAuthorized(address forwarder, bool authorized) external;
}

/// @notice The Earn stack rules a `VedaAuthorityOverlay` adds to what the RolesAuthority already allows.
interface IVedaStackAccess {
    /// @notice Whether `user` is a recorded engine or forwarding solver allowed to call `functionSig` on
    ///         `target`, one of the vault's Teller, honored Queues or honored stock solvers.
    function canStackCall(address user, address target, bytes4 functionSig) external view returns (bool);
}

/// @notice The seam through which a {VedaStackFactory} puts the engines it builds on the allowlist of a
///         Teller that checks accounts as well as callers. `VedaTellerLister` implements it.
interface IVedaTellerLister {
    /// @notice Whether the vault's administrator has named `factory` as a caller the lister accepts.
    function isFactory(address factory) external view returns (bool);
    /// @notice Lists `engine` on the vault's published Teller, or delists it.
    /// @return applied Whether the Teller's list now says so. Listing reverts when it does not;
    ///         delisting records the engine as delisted either way and reports whether the Teller
    ///         took the change.
    function setEngineListed(address engine, bool listed) external returns (bool applied);
}

/// @notice The wiring a `VedaStackFactory` reports, which an authorizer or a lister checks before
///         accepting it.
interface IVedaStackFactoryWiring {
    function authorizer() external view returns (address);
    function tellerLister() external view returns (address);
    function registry() external view returns (address);
}
