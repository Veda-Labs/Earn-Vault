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
/// @notice Grants and revokes two RolesAuthority roles for engines and forwarding solvers built by
///         factories the vault's administrator has named. Teller account admission is separate.
/// @dev The RolesAuthority gates `setUserRole` by function, not by its arguments. Its administrator
///      points its external authority at this contract, which permits only this contract to call
///      `setUserRole`. The roles, RolesAuthority, registry, and vault are fixed at construction.
///      A named factory must report this granter and this registry. The factory is responsible for
///      passing only contracts it built. Before granting, this contract checks that the BoringVault
///      still uses this RolesAuthority, that the RolesAuthority still uses this contract and has an
///      owner, and that the role reaches no protected custody or role-administration function.
///      Roles with other capabilities or existing holders require administrator review before setup.
///      If a Teller separately checks account membership, the deployment process must arrange it;
///      this contract does not read or write Teller membership and role authorization alone does not
///      prove that deposits or exits will work.
/// @custom:invariant engineRole != forwarderRole && !isFactory[address(0)]
/// @custom:invariant address(rolesAuthority) != address(0) && address(registry) != address(0) && vault != address(0)
contract VedaRoleGranter is IVedaStackAuthorizer, IAuthority {
    IRolesAuthority public immutable rolesAuthority;
    IVedaVaultRegistry public immutable registry;
    address public immutable vault;
    uint8 public immutable engineRole;
    uint8 public immutable forwarderRole;

    /// @notice The stack factories that may request role changes.
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
    ///      nor revoke; the roles its stacks hold stay until the owner clears them.
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

    // ------------------------------------------------------------------
    // Named factories
    // ------------------------------------------------------------------

    /// @notice Grants or revokes the Engine role for a stack built by a named factory.
    /// @dev This changes only the RolesAuthority role. A separate Teller membership rule, if any,
    ///      remains the responsibility of its own administrator or admission service.
    function setEngineAuthorized(address engine, bool authorized) external onlyFactory {
        _setRole(engine, engineRole, authorized);
    }

    /// @notice Gives `forwarder` the Earn forwarder role, or takes it away.
    /// @custom:ensures isFactory[msg.sender]
    function setForwarderAuthorized(address forwarder, bool authorized) external onlyFactory {
        _setRole(forwarder, forwarderRole, authorized);
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

    /// @notice Reverts unless this granter serves `publishedRegistry` and `factory` and could grant
    ///         both roles now. It does not inspect Teller account admission.
    function assertSetup(IVedaVaultRegistry publishedRegistry, address factory) external view {
        if (address(publishedRegistry) != address(registry)) {
            revert RegistryMismatch(address(publishedRegistry), address(registry));
        }
        if (!isFactory[factory]) revert FactoryNotWired(factory);
        _requireGrantable(engineRole);
        _requireGrantable(forwarderRole);
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

    /// @dev What must hold before `role` is handed out.
    function _requireGrantable(uint8 role) private view {
        _requireSoleRoleWriter();
        (address target, bytes4 functionSig) = _protectedCapability(role);
        if (target != address(0)) revert RoleReachesProtectedFunction(role, target, functionSig);
    }

    /// @dev This contract is the only path to the role table besides the owner, there is an owner who
    ///      can still cut it off, and that role table is the one the BoringVault obeys.
    function _requireSoleRoleWriter() private view {
        address currentAuthority = IAuth(address(rolesAuthority)).authority();
        if (currentAuthority != address(this)) revert NotRolesAuthorityAuthority(currentAuthority);
        if (IAuth(address(rolesAuthority)).owner() == address(0)) revert RolesAuthorityHasNoOwner();
        address vaultAuthority = IAuth(vault).authority();
        if (vaultAuthority != address(rolesAuthority)) revert VaultAuthorityMismatch(vaultAuthority);
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
