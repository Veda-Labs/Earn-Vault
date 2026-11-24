// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IVedaVaultRegistry } from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAccountant } from "../../../../interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../interfaces/external/veda/IBoringVault.sol";
import { IAuth, IAuthority, IBoringVaultCustody } from "../../../../interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../interfaces/external/veda/ITeller.sol";

/// @title VedaVaultRegistry
/// @notice Per-vault source of truth for the Teller, optional tracking Queue with its stock solver, and
///         Accountant attached to one BoringVault. It is the periphery registry of every {VedaEngine}
///         a {VedaStackFactory} builds on that vault: what `VedaPeripheryRegistry` is to one engine,
///         for all of them.
/// @dev Ownerless and immutable to one BoringVault and base asset. Only the vault's administrator
///      publishes: the BoringVault's owner, or the owner of the BoringVault's current authority. Both
///      already hold full custody power over the vault, so the registry adds no new trust root, and both
///      are read live, so the registry follows the vault through an ownership or authority change.
///
///      ACTIVATION STAYS WITH EACH ENGINE. A publication changes no engine. An engine keeps the tuple
///      it cached until its owner pauses its EarnVault's deposits and calls `syncVedaPeriphery`, which
///      checks the wiring again, the report's age, and the safe rate against the owner's bounds. So a
///      replaced Teller, Queue and solver must stay live until every engine has moved and every
///      request on the old Queue is closed. Publication checks what an engine does not: that the
///      Teller can already mint and burn the vault's shares, that a Queue comes with a stock solver,
///      and that an optional Queue Teller pointer matches the published Teller. It cannot show that a
///      module's bytecode is benign, that the Earn stacks hold permissions on
///      the new modules, or that a separate account-admission policy accepts them. Those checks stay
///      with the review of the publication.
///
///      IT BINDS NO ENGINE. See {engine}.
contract VedaVaultRegistry is IVedaVaultRegistry {
    IBoringVault public immutable vault;
    address public immutable baseAsset;

    ITeller public teller;
    uint64 public version;
    IBoringQueue public queue;
    IAccountant public accountant;
    IBoringSolver public solver;

    event VedaVaultPeripheryPublished(
        uint64 indexed version, address indexed teller, address indexed queue, address accountant, address solver
    );

    error InvalidVedaPeriphery(address account);
    error InvalidVedaPeripheryWiring(address component, address expected, address actual);
    error NotVaultAdmin(address caller);
    error QueueSolverMismatch(address queue, address solver);
    error QueueTellerMismatch(address queue, address expected, address actual);
    error QueueTrackingDisabled(address queue);
    error TellerNotAuthorizedOnVault(address teller, bytes4 functionSig);
    error ZeroAddress();

    modifier onlyVaultAdmin() {
        if (!isVaultAdmin(msg.sender)) revert NotVaultAdmin(msg.sender);
        _;
    }

    constructor(IBoringVault vault_, address baseAsset_) {
        _validateContract(address(vault_));
        _validateContract(baseAsset_);
        vault = vault_;
        baseAsset = baseAsset_;
    }

    /// @notice Publishes the vault's Teller, optional Queue with its stock solver, and Accountant.
    /// @dev New engines are built on this tuple, and an existing engine moves to it when its owner
    ///      activates it. `newQueue` and `newSolver` are both zero for immediate-only operation, or
    ///      both set.
    function publish(ITeller newTeller, IBoringQueue newQueue, IAccountant newAccountant, IBoringSolver newSolver)
        external
        onlyVaultAdmin
    {
        _validateWiring(newTeller, newQueue, newAccountant, newSolver);

        teller = newTeller;
        queue = newQueue;
        accountant = newAccountant;
        solver = newSolver;
        uint64 newVersion = ++version;
        emit VedaVaultPeripheryPublished(
            newVersion, address(newTeller), address(newQueue), address(newAccountant), address(newSolver)
        );
    }

    /// @notice The answer a {VedaEngine} needs before it binds its EarnVault: the caller itself.
    /// @dev A `VedaEngine` binds only when its registry names it as the registry's engine, which is how
    ///      a one-engine `VedaPeripheryRegistry` lets the vault's owner pick that engine. This registry
    ///      serves every engine on the vault and picks none, so it gives each caller its own address
    ///      and the check passes for all of them. Which engines the vault serves is decided where the
    ///      permissions are: by the {VedaRoleGranter}, for the engines a named factory built. Read
    ///      off-chain, this returns the address the call was made from and says nothing.
    function engine() external view returns (address) {
        return msg.sender;
    }

    /// @notice Whether `account` administers the BoringVault: its owner, or the owner of its authority.
    /// @dev The zero address is never an administrator, so a renounced owner admits no one. A vault
    ///      without an authority, or an authority without a well-formed `owner()`, contributes none.
    function isVaultAdmin(address account) public view returns (bool) {
        if (account == address(0)) return false;
        if (account == vault.owner()) return true;
        (bool hasAuthority, address authority) = _tryReadAddress(address(vault), IAuth.authority.selector);
        if (!hasAuthority) return false;
        (bool hasOwner, address authorityOwner) = _tryReadAddress(authority, IAuth.owner.selector);
        return hasOwner && authorityOwner == account;
    }

    /// @dev Reads an address getter without reverting on a missing contract, a revert, or malformed data.
    function _tryReadAddress(address target, bytes4 selector) private view returns (bool ok, address value) {
        if (target.code.length == 0) return (false, address(0));
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || result.length != 32) return (false, address(0));
        uint256 word = abi.decode(result, (uint256));
        if (word > type(uint160).max) return (false, address(0));
        // Bounded above, so the downcast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(word)));
    }

    function _validateWiring(
        ITeller newTeller,
        IBoringQueue newQueue,
        IAccountant newAccountant,
        IBoringSolver newSolver
    ) private view {
        _validateContract(address(newTeller));
        _validateContract(address(newAccountant));

        address expectedVault = address(vault);
        _requireWiring(address(newTeller), expectedVault, newTeller.vault());
        _requireWiring(address(newTeller), address(newAccountant), newTeller.accountant());
        _requireTellerReachesVault(address(newTeller));
        if (address(newQueue) == address(0)) {
            // A solver settles a Queue's requests; without a Queue there is nothing for it to settle.
            if (address(newSolver) != address(0)) revert QueueSolverMismatch(address(0), address(newSolver));
        } else {
            _validateContract(address(newQueue));
            // A Queue whose requests nothing can settle would strand every queued exit.
            if (address(newSolver) == address(0)) revert QueueSolverMismatch(address(newQueue), address(0));
            _validateContract(address(newSolver));
            // The solver has no wiring to read, so at least it is none of the contracts already named.
            if (
                address(newSolver) == expectedVault || address(newSolver) == address(newTeller)
                    || address(newSolver) == address(newQueue) || address(newSolver) == address(newAccountant)
                    || address(newSolver) == address(this)
            ) revert InvalidVedaPeriphery(address(newSolver));
            _requireWiring(address(newQueue), expectedVault, newQueue.boringVault());
            _requireWiring(address(newQueue), address(newAccountant), newQueue.accountant());
            if (!newQueue.trackWithdrawsOnChain()) revert QueueTrackingDisabled(address(newQueue));
            (bool hasTeller, address queueTeller) = _tryReadAddress(address(newQueue), bytes4(keccak256("teller()")));
            if (hasTeller && queueTeller != address(0) && queueTeller != address(newTeller)) {
                revert QueueTellerMismatch(address(newQueue), address(newTeller), queueTeller);
            }
        }
        _requireWiring(address(newAccountant), expectedVault, newAccountant.vault());
        _requireWiring(address(newAccountant), baseAsset, newAccountant.base());
    }

    /// @dev Every deposit mints through the Teller and every immediate exit burns through it, so the
    ///      Teller must already be the vault's owner or be allowed `enter` and `exit` by its authority.
    ///      An engine does not check this before it activates a tuple.
    function _requireTellerReachesVault(address newTeller) private view {
        if (newTeller == vault.owner()) return;
        (bool hasAuthority, address authority) = _tryReadAddress(address(vault), IAuth.authority.selector);
        bool canAsk = hasAuthority && authority.code.length != 0;
        bytes4[2] memory vaultFunctions = [IBoringVaultCustody.enter.selector, IBoringVaultCustody.exit.selector];
        for (uint256 i = 0; i < vaultFunctions.length; i++) {
            if (!canAsk || !IAuthority(authority).canCall(newTeller, address(vault), vaultFunctions[i])) {
                revert TellerNotAuthorizedOnVault(newTeller, vaultFunctions[i]);
            }
        }
    }

    function _validateContract(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert InvalidVedaPeriphery(account);
    }

    function _requireWiring(address component, address expected, address actual) private pure {
        if (actual != expected) revert InvalidVedaPeripheryWiring(component, expected, actual);
    }
}
