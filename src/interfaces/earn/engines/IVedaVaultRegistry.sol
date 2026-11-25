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

/// @notice The seam through which a {VedaStackFactory} grants RolesAuthority roles to the engines
///         and forwarding solvers it builds. Teller account admission is separate.
interface IVedaStackAuthorizer {
    /// @notice Whether the vault's administrator has named `factory` as a caller the authorizer accepts.
    function isFactory(address factory) external view returns (bool);
    function setEngineAuthorized(address engine, bool authorized) external;
    function setForwarderAuthorized(address forwarder, bool authorized) external;
}

/// @notice The owner a {VedaStackFactory} gives its forwarding solvers when that owner is a contract that
///         approves the vault's solvers on each one. `VedaForwarderSteward` implements it.
interface IVedaForwarderSteward {
    /// @notice Approves every solver the steward lists on `forwarder`, which the steward must own.
    /// @return approved How many listed solvers `forwarder` now has approved.
    function seed(address forwarder) external returns (uint256 approved);
}

/// @notice The wiring a `VedaStackFactory` reports, which an authorizer checks before accepting it.
interface IVedaStackFactoryWiring {
    function authorizer() external view returns (address);
    function registry() external view returns (address);
}
