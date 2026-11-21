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

/// @title VedaRoleGranter
/// @notice Grants and revokes exactly two roles on one BoringVault's RolesAuthority, and only for the
///         stack factories the RolesAuthority's owner names: the Earn engine role, for the engines a
///         {VedaStackFactory} builds, and the Earn forwarder role, for their forwarding solvers. It is
///         the only path from a factory into the vault's permissions.
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
///      WHICH FACTORIES. Only the RolesAuthority's owner names a factory, and it can name several: a
///      factory is pinned to exact engine and core code, so a new release is a new factory, while the
///      one before it still serves the stacks it built. A factory is accepted only if it reports this
///      granter as its authorizer and this granter's registry as its own, so a factory that reads some
///      other registry cannot be named by mistake. That is a check of the factory's wiring, not of its
///      code: the owner still has to know what code it is naming.
///
///      WITHDRAWING IT. The RolesAuthority's owner cuts this contract off by pointing `authority`
///      elsewhere. That stops new grants and also this contract's revocations: roles already granted
///      stay until the owner clears them or removes the roles' capabilities, and the factories' pausers
///      can no longer revoke through it. Pausing registrations and revoking through a factory are the
///      fast controls; repointing the authority is the owner's final one.
///
///      WHAT BOUNDS IT. This contract can reach `setUserRole` with any arguments, so its own code is the
///      bound, and it is kept to that: both role numbers, the RolesAuthority and the registry are fixed
///      at construction, the only external writes are the two `setUserRole` calls below, and there is no
///      upgrade and no other entry point. Before a grant it also refuses, at the cost of a few reads, to
///      act unless it is still the RolesAuthority's authority, the RolesAuthority still has an owner who
///      could cut it off, the BoringVault still answers to that RolesAuthority, and the role has no
///      capability on the BoringVault's custody functions or on the RolesAuthority's own
///      administration. Those twelve functions are the ones that move custody or change roles; a role
///      number that collides with a capability elsewhere is not detected here, and is harmless only
///      because the holders are the fixed-code contracts a factory builds. Revocation skips these
///      checks so it works whenever the RolesAuthority admits it.
/// The role numbers, RolesAuthority, registry and vault never change, and the two roles differ.
/// @custom:invariant engineRole != forwarderRole && !isFactory[address(0)]
/// @custom:invariant address(rolesAuthority) != address(0) && address(registry) != address(0) && vault != address(0)
contract VedaRoleGranter is IVedaStackAuthorizer, IAuthority {
    IRolesAuthority public immutable rolesAuthority;
    /// @notice The vault's registry: every factory this granter serves must build on it.
    IVedaVaultRegistry public immutable registry;
    /// @notice The registry's BoringVault, whose custody functions a granted role must not reach.
    address public immutable vault;
    uint8 public immutable engineRole;
    uint8 public immutable forwarderRole;

    /// @notice The stack factories the RolesAuthority's owner has named: the only callers.
    mapping(address factory => bool named) public isFactory;

    event EarnRoleUpdated(address indexed account, uint8 indexed role, bool enabled);
    event StackFactoryChanged(address indexed factory, bool named);

    error FactoryNotWired(address factory);
    error InvalidAccount(address account);
    error InvalidAuthorizerWiring(address account);
    error NotFactory(address caller);
    error NotRolesAuthorityAuthority(address currentAuthority);
    error NotRolesAuthorityOwner(address caller);
    error RegistryMismatch(address expected, address actual);
    error RolesAuthorityHasNoOwner();
    error RoleReachesProtectedFunction(uint8 role, address target, bytes4 functionSig);
    error RoleUpdateFailed(address account, uint8 role, bool enabled);
    error SameRole(uint8 role);
    error VaultAuthorityMismatch(address vaultAuthority);
    error ZeroAddress();

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

    /// @notice Names a stack factory as a caller, or stops accepting one.
    /// @dev Only the RolesAuthority's owner. A named factory must report this granter as its authorizer
    ///      and this granter's registry as its own. A factory that is no longer named can neither grant
    ///      nor revoke; the roles its stacks hold stay until the owner clears them.
    /// @custom:ensures msg.sender == IAuth(address(rolesAuthority)).owner() && isFactory[factory] == named
    function setFactory(address factory, bool named) external {
        address owner = IAuth(address(rolesAuthority)).owner();
        if (msg.sender != owner || owner == address(0)) revert NotRolesAuthorityOwner(msg.sender);
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

    /// @notice Gives `engine` the Earn engine role, or takes it away.
    /// @custom:ensures isFactory[msg.sender]
    function setEngineAuthorized(address engine, bool authorized) external {
        _setRole(engine, engineRole, authorized);
    }

    /// @notice Gives `forwarder` the Earn forwarder role, or takes it away.
    /// @custom:ensures isFactory[msg.sender]
    function setForwarderAuthorized(address forwarder, bool authorized) external {
        _setRole(forwarder, forwarderRole, authorized);
    }

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

    /// @notice Reverts unless this granter serves `publishedRegistry` and `factory` and could grant both
    ///         roles now: the last call of the administrator's setup batch.
    /// @dev The batch passes the registry it publishes on and the factory it names, so a granter built
    ///      for another registry, or a factory that was not named, undoes the whole batch. This checks
    ///      wiring and the pre-grant conditions. It does not check any contract's code.
    function assertSetup(IVedaVaultRegistry publishedRegistry, address factory) external view {
        if (address(publishedRegistry) != address(registry)) {
            revert RegistryMismatch(address(publishedRegistry), address(registry));
        }
        if (!isFactory[factory]) revert FactoryNotWired(factory);
        _requireGrantable(engineRole);
        _requireGrantable(forwarderRole);
    }

    /// @dev The only writer to the RolesAuthority. `role` is always one of the two immutable roles.
    function _setRole(address account, uint8 role, bool enabled) private {
        if (!isFactory[msg.sender]) revert NotFactory(msg.sender);
        if (enabled) {
            // A role belongs on a contract a factory built, never on a key or an empty address.
            if (account.code.length == 0) revert InvalidAccount(account);
            _requireGrantable(role);
        }
        rolesAuthority.setUserRole(account, role, enabled);
        if (rolesAuthority.doesUserHaveRole(account, role) != enabled) revert RoleUpdateFailed(account, role, enabled);
        emit EarnRoleUpdated(account, role, enabled);
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
}
