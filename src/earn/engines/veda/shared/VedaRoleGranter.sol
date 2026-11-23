// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {
    IVedaStackAuthorizer,
    IVedaStackFactoryWiring,
    IVedaVaultRegistry
} from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import {
    IAuth,
    IAuthority,
    IBoringVaultCustody,
    IRolesAuthority
} from "../../../../interfaces/external/veda/IRolesAuthority.sol";
import { ITellerAllowlist } from "../../../../interfaces/external/veda/ITellerAllowlist.sol";
import { VedaTellerAllowlist } from "./VedaTellerAllowlist.sol";

/// @title VedaRoleGranter
/// @notice Admits the Earn stacks a {VedaStackFactory} builds to one BoringVault, and only for the
///         factories the RolesAuthority's owner names. It grants and revokes exactly two roles on the
///         vault's RolesAuthority: the Earn engine role, for engines, and the Earn forwarder role, for
///         their forwarding solvers. Where the vault's Teller admits by account, which the owner says
///         with one flag, it also puts each engine on that Teller's list. It is the only path from a
///         factory into the vault's permissions.
///
/// @dev WHY IT IS THE ROLESAUTHORITY'S AUTHORITY. A RolesAuthority gates by function, not by argument:
///      whoever may call `setUserRole` may give any role to anyone. That power cannot be narrowed on the
///      RolesAuthority, so it is narrowed here. The vault's administrator points the RolesAuthority's own
///      `authority` at this contract, and {canCall} admits one triple: this contract, calling
///      `setUserRole`, on that RolesAuthority. Nothing else changes: the RolesAuthority's owner keeps
///      every power, no role number is spent on a registrar, and no capability row that targets the
///      RolesAuthority becomes live, because the RolesAuthority never consults its own role table for
///      calls on itself. That holds when the RolesAuthority had no authority before; one it had is
///      displaced, with whatever it admitted.
///
///      ANY TELLER. A Teller either gates its callers, and then the engine role's capabilities are what
///      admit an engine, or it also checks the account whose position changes against a list, and
///      then an engine must be on that list whoever may call. {tellerAllowlist} says which: while it
///      is set, authorizing an engine also lists it on the registry's published Teller, and revoking
///      one delists it. The owner lets this contract call `setAllowedAccounts` on such a Teller. The
///      role is granted either way, since the Queue and the stock solver still gate callers. The list
///      lives in the Teller, so a newly published Teller starts without the vault's engines: {relist}
///      carries every engine that still holds the engine role onto it, and an engine's owner
///      activates the new Teller after that. {redelist} takes revoked engines off a Teller they
///      reached by another route. Both are open to anyone and write only what this contract or the
///      owner already decided.
///
///      WHICH FACTORIES. Only the RolesAuthority's owner names a factory, and it can name several: a
///      factory is pinned to exact engine and core code, so a new release is a new factory, while the
///      one before it still serves the stacks it built. A factory is accepted only if it reports this
///      granter as its authorizer and this granter's registry as its own, so a factory that reads some
///      other registry cannot be named by mistake. That is a check of the factory's wiring, not of its
///      code: the owner still has to know what code it is naming.
///
///      WITHDRAWING IT. The RolesAuthority's owner cuts this contract off by pointing `authority`
///      elsewhere. That stops new grants and also this contract's role revocations: roles already
///      granted stay until the owner clears them or removes the roles' capabilities. Pausing
///      registrations and revoking through a factory are the fast controls; repointing the authority
///      is the owner's final one.
///
///      WHAT BOUNDS IT. This contract can reach `setUserRole` with any arguments and, where the owner
///      allowed it, `setAllowedAccounts` with any accounts, so its own code is the bound, and it is
///      kept to that: both role numbers, the RolesAuthority and the registry are fixed at construction,
///      there is no upgrade, and its only external writes are `setUserRole` for those two roles and
///      `setAllowedAccounts` for engines. It lists only on the registry's published Teller, and only
///      an engine a named factory asked for or one that holds the engine role. It delists only an
///      engine it listed or one that holds the engine role, on that Teller, on the Teller the engine
///      itself reports, and on the one it last listed the engine on. Before a grant it also refuses, at the cost of a
///      few reads, to act unless it is still the RolesAuthority's authority, the RolesAuthority still
///      has an owner who could cut it off, the BoringVault still answers to that RolesAuthority, and
///      the role has no capability on the BoringVault's custody functions or on the RolesAuthority's
///      own administration. Those twelve functions are the ones that move custody or change roles; a
///      role number that collides with a capability elsewhere is not detected here, so the two role
///      numbers must be ones the vault uses for nothing else. Revocation skips these checks so it
///      works whenever the RolesAuthority admits it.
///
///      THE RECORD IS NOT THE LIST. `listedOn` says what this contract last wrote. The owner can
///      change a Teller's list directly, and this contract does not learn of it. {relist} does not
///      repeat its latest listing, so a direct delisting on the Teller that listing was made on stays,
///      but the engine is carried to the next Teller published while it holds the engine role; only a
///      revocation through its factory keeps an engine off. A Teller that stops enforcing its list
///      admits everyone whatever is recorded here.
/// The role numbers, RolesAuthority, registry and vault never change, and the two roles differ.
/// @custom:invariant engineRole != forwarderRole && !isFactory[address(0)]
/// @custom:invariant address(rolesAuthority) != address(0) && address(registry) != address(0) && vault != address(0)
contract VedaRoleGranter is IVedaStackAuthorizer, IAuthority {
    /// @dev Marks an engine this contract listed and whose authorization was since revoked. Never a Teller.
    address private constant DELISTED = address(1);

    IRolesAuthority public immutable rolesAuthority;
    /// @notice The vault's registry: every factory this granter serves must build on it, and its
    ///         published Teller is the one this granter lists on.
    IVedaVaultRegistry public immutable registry;
    /// @notice The registry's BoringVault, whose custody functions a granted role must not reach.
    address public immutable vault;
    uint8 public immutable engineRole;
    uint8 public immutable forwarderRole;

    /// @notice The stack factories the RolesAuthority's owner has named: the only callers.
    mapping(address factory => bool named) public isFactory;
    /// @notice Whether the vault's Teller admits by account, so that authorizing an engine also lists
    ///         it on the published Teller. Clear for a Teller that gates callers only.
    bool public tellerAllowlist;
    /// @notice The Teller this contract last listed `engine` on. Zero for an engine it never listed,
    ///         and `address(1)` for one whose authorization was revoked after it was listed.
    mapping(address engine => address teller) public listedOn;

    event EarnRoleUpdated(address indexed account, uint8 indexed role, bool enabled);
    event StackFactoryChanged(address indexed factory, bool named);
    event TellerAllowlistChanged(bool enabled);
    event EngineListingChanged(address indexed engine, address indexed teller, bool listed);
    /// @notice A revoked engine is still on `teller`'s list, or the list could not be read. {redelist}
    ///         tries again.
    event EngineDelistingDeferred(address indexed engine, address indexed teller);
    /// @notice A revoked engine was delisted and still holds the engine role, which the RolesAuthority
    ///         did not let this contract clear. Its owner clears it.
    event EngineRoleRevocationDeferred(address indexed engine);

    error CannotListOnTeller(address teller);
    error FactoryNotWired(address factory);
    error InvalidAccount(address account);
    error InvalidAuthorizerWiring(address account);
    error ListingFailed(address engine, address teller);
    error ListNotEnforced(address teller);
    error ListWritableByAnyone(address teller);
    error NotFactory(address caller);
    error NotRolesAuthorityAuthority(address currentAuthority);
    error NotRolesAuthorityOwner(address caller);
    error QueueNotBound(address queue, address teller);
    error RegistryMismatch(address expected, address actual);
    error RolesAuthorityHasNoOwner();
    error RoleReachesProtectedFunction(uint8 role, address target, bytes4 functionSig);
    error RoleUpdateFailed(address account, uint8 role, bool enabled);
    error SameRole(uint8 role);
    error SolverNotListed(address solver, address teller);
    error TellerAllowlistOff();
    error TellerEnforcesList(address teller);
    error VaultAuthorityMismatch(address vaultAuthority);
    error ZeroAddress();

    modifier onlyRolesAuthorityOwner() {
        address owner = IAuth(address(rolesAuthority)).owner();
        if (msg.sender != owner || owner == address(0)) revert NotRolesAuthorityOwner(msg.sender);
        _;
    }

    modifier onlyFactory() {
        if (!isFactory[msg.sender]) revert NotFactory(msg.sender);
        _;
    }

    constructor(
        IRolesAuthority rolesAuthority_,
        IVedaVaultRegistry registry_,
        uint8 engineRole_,
        uint8 forwarderRole_
    ) {
        if (address(rolesAuthority_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(rolesAuthority_).code.length == 0) revert InvalidAuthorizerWiring(address(rolesAuthority_));
        if (address(registry_).code.length == 0) revert InvalidAuthorizerWiring(address(registry_));
        address vault_ = address(registry_.vault());
        if (vault_ == address(0)) revert ZeroAddress();
        if (vault_.code.length == 0) revert InvalidAuthorizerWiring(vault_);
        if (engineRole_ == forwarderRole_) revert SameRole(engineRole_);
        rolesAuthority = rolesAuthority_;
        registry = registry_;
        vault = vault_;
        engineRole = engineRole_;
        forwarderRole = forwarderRole_;
    }

    /// @notice The authority surface the RolesAuthority consults for calls on itself.
    /// @dev Admits only this contract calling `setUserRole` on its RolesAuthority. Every other caller,
    ///      target and function is refused, so the RolesAuthority's remaining administration
    ///      (`setRoleCapability`, `setPublicCapability`, `setAuthority`, `transferOwnership`) stays with
    ///      its owner alone, and a contract that points its authority here by mistake admits no one.
    /// @custom:ensures result == (user == address(this) && target == address(rolesAuthority) && functionSig == IRolesAuthority.setUserRole.selector)
    function canCall(address user, address target, bytes4 functionSig) external view returns (bool) {
        return user == address(this) && target == address(rolesAuthority)
            && functionSig == IRolesAuthority.setUserRole.selector;
    }

    // ------------------------------------------------------------------
    // The RolesAuthority's owner
    // ------------------------------------------------------------------

    /// @notice Names a stack factory as a caller, or stops accepting one.
    /// @dev Only the RolesAuthority's owner. A named factory must report this granter as its authorizer
    ///      and this granter's registry as its own. A factory that is no longer named can neither grant
    ///      nor revoke; the roles and listings its stacks hold stay until the owner clears them.
    /// @custom:ensures msg.sender == IAuth(address(rolesAuthority)).owner() && isFactory[factory] == named
    function setFactory(address factory, bool named) external onlyRolesAuthorityOwner {
        if (named) {
            if (factory.code.length == 0) revert FactoryNotWired(factory);
            IVedaStackFactoryWiring wiring = IVedaStackFactoryWiring(factory);
            if (wiring.authorizer() != address(this) || wiring.registry() != address(registry)) {
                revert FactoryNotWired(factory);
            }
        }
        isFactory[factory] = named;
        emit StackFactoryChanged(factory, named);
    }

    /// @notice Says whether the vault's Teller admits by account.
    /// @dev Only the RolesAuthority's owner. Setting it changes no list: engines authorized while it
    ///      was clear reach the published Teller's list through {relist}, and {assertSetup} checks the
    ///      flag against the published Teller. Clearing it stops new listings and leaves every listing
    ///      and record in place; revoking an engine still delists it.
    /// @custom:ensures msg.sender == IAuth(address(rolesAuthority)).owner() && tellerAllowlist == enabled
    function setTellerAllowlist(bool enabled) external onlyRolesAuthorityOwner {
        tellerAllowlist = enabled;
        emit TellerAllowlistChanged(enabled);
    }

    // ------------------------------------------------------------------
    // Named factories
    // ------------------------------------------------------------------

    /// @notice Gives `engine` the Earn engine role and, while {tellerAllowlist} is set, a place on the
    ///         published Teller's list; or takes both away.
    /// @dev Only a named factory, which asks only for engines it built. Authorizing reverts unless the
    ///      role is held and, where the engine is listed, the Teller reports it listed. Revoking
    ///      clears the role and delists the engine wherever this contract can find it listed: each
    ///      step runs whether or not another fails, a Teller that does not take the change is named
    ///      by `EngineDelistingDeferred`, and the engine is recorded so that nothing here lists it
    ///      again. Revoking reverts only when the role could not be cleared and there was no listing
    ///      to remove.
    /// @custom:ensures isFactory[msg.sender]
    function setEngineAuthorized(address engine, bool authorized) external onlyFactory {
        if (!authorized) {
            _revokeEngine(engine);
            return;
        }
        _setRole(engine, engineRole, true);
        if (tellerAllowlist) {
            _list(engine);
        } else if (listedOn[engine] == DELISTED) {
            // Authorized again on a Teller without a list: eligible for the next Teller that has one.
            delete listedOn[engine];
        }
    }

    /// @notice Gives `forwarder` the Earn forwarder role, or takes it away.
    /// @dev A forwarding solver needs no listing: a Teller's list is asked about the engine that owns
    ///      a request and about the stock solver, never about the forwarding solver.
    /// @custom:ensures isFactory[msg.sender]
    function setForwarderAuthorized(address forwarder, bool authorized) external onlyFactory {
        _setRole(forwarder, forwarderRole, authorized);
    }

    // ------------------------------------------------------------------
    // Anyone: carry the list across Tellers
    // ------------------------------------------------------------------

    /// @notice Lists engines that hold the engine role on the Teller published now.
    /// @dev Open to anyone while {tellerAllowlist} is set, since it lists only accounts a named factory
    ///      or the RolesAuthority's owner already gave the engine role. It is how the vault's engines
    ///      reach a newly published Teller before their owners activate it, and how engines authorized
    ///      before the flag was set reach the list. Skipped, so that one of them does not fail a batch:
    ///      an account without the role or without code, an engine revoked through its factory, and
    ///      an engine whose latest listing by this contract was on this Teller, so that a listing the
    ///      owner has since removed there directly is not restored.
    /// @return carried How many engines were listed.
    function relist(address[] calldata engines) external returns (uint256 carried) {
        if (!tellerAllowlist) revert TellerAllowlistOff();
        address teller = address(registry.teller());
        address[] memory accounts = new address[](engines.length);
        for (uint256 i = 0; i < engines.length; i++) {
            address engine = engines[i];
            address last = listedOn[engine];
            if (last == DELISTED || last == teller || engine.code.length == 0) continue;
            if (!rolesAuthority.doesUserHaveRole(engine, engineRole)) continue;
            listedOn[engine] = teller;
            accounts[carried++] = engine;
        }
        if (carried == 0) return 0;
        // Shorten the array in place to the entries used.
        assembly ("memory-safe") {
            mstore(accounts, carried)
        }
        ITellerAllowlist(teller).setAllowedAccounts(accounts, true);
        for (uint256 i = 0; i < carried; i++) {
            if (!ITellerAllowlist(teller).allowedAccounts(accounts[i])) revert ListingFailed(accounts[i], teller);
            emit EngineListingChanged(accounts[i], teller, true);
        }
    }

    /// @notice Takes engines revoked through their factory off the Teller published now and off the
    ///         Teller each engine itself uses.
    /// @dev Open to anyone, since it only removes what a pauser already removed. It finishes a
    ///      delisting a Teller did not take, and keeps a revoked engine off a Teller it reached by
    ///      another route: one published again with its old list, or one the owner listed engines on
    ///      directly. Engines this contract does not record as revoked are skipped.
    /// @return removed How many engines are now off both lists.
    function redelist(address[] calldata engines) external returns (uint256 removed) {
        for (uint256 i = 0; i < engines.length; i++) {
            if (listedOn[engines[i]] == DELISTED && _delist(engines[i], DELISTED)) removed++;
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Whether a grant would pass this contract's own checks for `role` right now.
    /// @dev For a monitor: true only while this contract is the RolesAuthority's authority, the
    ///      RolesAuthority has an owner, the BoringVault answers to it, and `role` reaches no protected
    ///      function.
    function isGrantSafe(uint8 role) external view returns (bool) {
        if (IAuth(address(rolesAuthority)).authority() != address(this)) return false;
        if (IAuth(address(rolesAuthority)).owner() == address(0)) return false;
        if (IAuth(vault).authority() != address(rolesAuthority)) return false;
        (address target,) = _protectedCapability(role);
        return target == address(0);
    }

    /// @notice Reverts unless this granter serves `publishedRegistry` and `factory`, could grant both
    ///         roles now, and {tellerAllowlist} matches the published Teller: the last call of the
    ///         administrator's setup batch, and of every publication of a Teller.
    /// @dev The batch passes the registry it publishes on and the factory it names, so a granter built
    ///      for another registry, or a factory that was not named, undoes the whole batch. This checks
    ///      wiring and the pre-grant conditions. It does not check any contract's code.
    ///
    ///      With the flag clear, the published Teller must not refuse this contract as an account: a
    ///      Teller that enforces a list would refuse every engine authorized here. With the flag set,
    ///      the Teller must enforce its list in both directions, this contract must be allowed to
    ///      write it and an account holding no role must not be, and a published Queue must apply that
    ///      same list and have its stock solver on it; without those, listing an engine admits
    ///      nothing, delisting one stops nothing, or queued exits cannot settle. It cannot show that no
    ///      other account holds the role that writes the list. This contract must not itself be on the
    ///      list, which is how it tells an enforced list from an idle one.
    function assertSetup(IVedaVaultRegistry publishedRegistry, address factory) external view {
        if (address(publishedRegistry) != address(registry)) {
            revert RegistryMismatch(address(publishedRegistry), address(registry));
        }
        if (!isFactory[factory]) revert FactoryNotWired(factory);
        _requireGrantable(engineRole);
        _requireGrantable(forwarderRole);

        address teller = address(registry.teller());
        (bool depositChecked, bool depositAllowed) = VedaTellerAllowlist.tryIsDepositAllowed(teller, address(this));
        (bool withdrawChecked, bool withdrawAllowed) = VedaTellerAllowlist.tryIsWithdrawAllowed(teller, address(this));
        if (!tellerAllowlist) {
            if ((depositChecked && !depositAllowed) || (withdrawChecked && !withdrawAllowed)) {
                revert TellerEnforcesList(teller);
            }
            return;
        }
        if (!depositChecked || !withdrawChecked || !_mayWriteList(teller, address(this))) {
            revert CannotListOnTeller(teller);
        }
        if (depositAllowed || withdrawAllowed) revert ListNotEnforced(teller);
        // The registry holds no role, so a Teller that lets it write the list lets everyone.
        if (_mayWriteList(teller, address(registry))) revert ListWritableByAnyone(teller);
        address queue = address(registry.queue());
        if (queue != address(0)) {
            (bool queueChecks, address queueTeller) = VedaTellerAllowlist.tryTeller(queue);
            if (!queueChecks || queueTeller != teller) revert QueueNotBound(queue, teller);
            address solver = address(registry.solver());
            (bool readable, bool solverListed) = VedaTellerAllowlist.tryAllowedAccounts(teller, solver);
            if (!readable || !solverListed) revert SolverNotListed(solver, teller);
        }
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev The only granting writer to the RolesAuthority. `role` is always one of the two immutable
    ///      roles, and the caller is a named factory.
    function _setRole(address account, uint8 role, bool enabled) private {
        if (enabled) {
            // A role belongs on a contract a factory built, never on a key or an empty address.
            if (account.code.length == 0) revert InvalidAccount(account);
            _requireGrantable(role);
        }
        rolesAuthority.setUserRole(account, role, enabled);
        if (rolesAuthority.doesUserHaveRole(account, role) != enabled) revert RoleUpdateFailed(account, role, enabled);
        emit EarnRoleUpdated(account, role, enabled);
    }

    /// @dev Clears the engine role and removes the engine's listings, each whether or not the other
    ///      works: a RolesAuthority that no longer admits this contract must not keep an engine on a
    ///      Teller's list, and a Teller that cannot be written must not keep the role in place. An
    ///      engine has listings to remove when this contract listed it, or when it holds the engine
    ///      role while the flag is set, which covers an engine the owner listed directly on a Teller
    ///      published after the engine was authorized. An account that never held the engine role and
    ///      was never listed here, such as the stock solver, cannot be delisted through this.
    function _revokeEngine(address engine) private {
        address last = listedOn[engine];
        bool delist = last != address(0) || (tellerAllowlist && rolesAuthority.doesUserHaveRole(engine, engineRole));
        // Recorded first, so that nothing here lists the engine again whatever follows.
        if (delist) listedOn[engine] = DELISTED;

        try rolesAuthority.setUserRole(engine, engineRole, false) { } catch { }
        if (rolesAuthority.doesUserHaveRole(engine, engineRole)) {
            // With no listing to remove either, nothing was revoked.
            if (!delist) revert RoleUpdateFailed(engine, engineRole, false);
            emit EngineRoleRevocationDeferred(engine);
        } else {
            emit EarnRoleUpdated(engine, engineRole, false);
        }
        if (delist) _delist(engine, last);
    }

    /// @dev Lists `engine`, which holds the engine role, on the published Teller.
    function _list(address engine) private {
        address teller = address(registry.teller());
        listedOn[engine] = teller;

        ITellerAllowlist(teller).setAllowedAccounts(_one(engine), true);
        // A Teller that accepted the call without recording it would leave the record above wrong.
        if (!ITellerAllowlist(teller).allowedAccounts(engine)) revert ListingFailed(engine, teller);
        emit EngineListingChanged(engine, teller, true);
    }

    /// @dev Takes `engine` off every Teller it can still use or was last listed on: the published
    ///      one, which its owner could activate; the one the engine reports, which it uses until
    ///      then; and `last`, where this contract listed it most recently. An engine can activate only
    ///      the published Teller, so a listing left on any other Teller is one it cannot use.
    /// @return applied Whether none of those lists holds the engine now.
    function _delist(address engine, address last) private returns (bool applied) {
        address published = address(registry.teller());
        (, address current) = VedaTellerAllowlist.tryTeller(engine);
        applied = _delistOn(published, engine);
        if (current != address(0) && current != published) applied = _delistOn(current, engine) && applied;
        if (last != address(0) && last != DELISTED && last != published && last != current) {
            applied = _delistOn(last, engine) && applied;
        }
    }

    /// @dev `applied` says the Teller's list does not hold the engine, not that the Teller refuses it:
    ///      an unenforced list refuses no one. A Teller that cannot be written or read is reported
    ///      and never stops the revocation.
    function _delistOn(address teller, address engine) private returns (bool applied) {
        (bool supported, bool listed) = VedaTellerAllowlist.tryAllowedAccounts(teller, engine);
        if (supported && !listed) return true;
        if (teller.code.length != 0) {
            try ITellerAllowlist(teller).setAllowedAccounts(_one(engine), false) {
                (supported, listed) = VedaTellerAllowlist.tryAllowedAccounts(teller, engine);
                applied = supported && !listed;
            } catch { }
        }
        if (applied) emit EngineListingChanged(engine, teller, false);
        else emit EngineDelistingDeferred(engine, teller);
    }

    /// @dev What must hold before `role` is handed out.
    function _requireGrantable(uint8 role) private view {
        // This contract is the only path to the role table besides the owner...
        address currentAuthority = IAuth(address(rolesAuthority)).authority();
        if (currentAuthority != address(this)) revert NotRolesAuthorityAuthority(currentAuthority);
        // ...there is an owner who can still cut it off...
        if (IAuth(address(rolesAuthority)).owner() == address(0)) revert RolesAuthorityHasNoOwner();
        // ...and the role table inspected below is the one the BoringVault obeys.
        address vaultAuthority = IAuth(vault).authority();
        if (vaultAuthority != address(rolesAuthority)) revert VaultAuthorityMismatch(vaultAuthority);
        (address target, bytes4 functionSig) = _protectedCapability(role);
        if (target != address(0)) revert RoleReachesProtectedFunction(role, target, functionSig);
    }

    /// @dev The first custody or role-administration function `role` can call, or zero when it can call
    ///      none. An Earn role is meant to reach the Teller's bulk paths, the Queue's request and
    ///      cancellation, or the stock solver's solve, and nothing here.
    function _protectedCapability(uint8 role) private view returns (address target, bytes4 functionSig) {
        bytes4[7] memory vaultFunctions = [
            bytes4(keccak256("manage(address,bytes,uint256)")),
            bytes4(keccak256("manage(address[],bytes[],uint256[])")),
            IBoringVaultCustody.enter.selector,
            IBoringVaultCustody.exit.selector,
            IBoringVaultCustody.setBeforeTransferHook.selector,
            IAuth.setAuthority.selector,
            IAuth.transferOwnership.selector
        ];
        for (uint256 i = 0; i < vaultFunctions.length; i++) {
            if (rolesAuthority.doesRoleHaveCapability(role, vault, vaultFunctions[i])) {
                return (vault, vaultFunctions[i]);
            }
        }
        bytes4[5] memory authorityFunctions = [
            IRolesAuthority.setUserRole.selector,
            IRolesAuthority.setRoleCapability.selector,
            IRolesAuthority.setPublicCapability.selector,
            IAuth.setAuthority.selector,
            IAuth.transferOwnership.selector
        ];
        for (uint256 i = 0; i < authorityFunctions.length; i++) {
            if (rolesAuthority.doesRoleHaveCapability(role, address(rolesAuthority), authorityFunctions[i])) {
                return (address(rolesAuthority), authorityFunctions[i]);
            }
        }
    }

    /// @dev Whether the Teller would accept `setAllowedAccounts` from `account`, as the Teller asks it.
    function _mayWriteList(address teller, address account) private view returns (bool) {
        if (IAuth(teller).owner() == account) return true;
        address authority = IAuth(teller).authority();
        return authority.code.length != 0
            && IAuthority(authority).canCall(account, teller, ITellerAllowlist.setAllowedAccounts.selector);
    }

    function _one(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
