// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {
    IVedaStackAccess,
    IVedaStackAuthorizer,
    IVedaStackFactoryWiring
} from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IBoringQueue } from "../../../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../interfaces/external/veda/IBoringVault.sol";
import { IAuth, IAuthority } from "../../../../interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../interfaces/external/veda/ITeller.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { VedaAuthorityOverlay } from "./VedaAuthorityOverlay.sol";
import { VedaVaultRegistry } from "./VedaVaultRegistry.sol";

/// @title VedaVaultAccessRegistry
/// @notice {VedaVaultRegistry} for a vault that authorizes its Earn stacks through a
///         {VedaAuthorityOverlay} instead of RolesAuthority roles. Besides the published modules it
///         holds the record the overlay reads: which engines and forwarding solvers are active, and
///         which Queues and stock solvers still serve open requests.
///
/// @dev Authorizing an engine is the vault's stack factory writing it into this record; revoking it
///      clears the flag. Nothing here writes to the RolesAuthority, and {canStackCall} never answers for
///      the BoringVault, so no entry in this record reaches custody.
///
///      The vault's administrator names the factories that may write the record and binds the overlay
///      that reads it. It can name several factories: a factory is pinned to exact engine and core
///      code, so a new release is a new factory, while the one before it still serves the stacks it
///      built. A factory is accepted only if it reports this registry as both its registry and its
///      authorizer; that checks its wiring, not its code. An overlay is fixed to one RolesAuthority, so
///      it can be replaced too. Only an overlay this registry created can be bound, so its code needs
///      no separate review, and it must pass through the RolesAuthority the BoringVault answers to now.
///      While an overlay is bound, a publication is refused unless its Teller, Queue and stock solver
///      already point at that overlay, since a module that does not would stop every stack at once.
///
///      A factory's pausers revoke through that factory, so they cannot reach an engine once the
///      administrator stops naming it. The administrator clears any entry directly with {revokeAccess}.
contract VedaVaultAccessRegistry is VedaVaultRegistry, IVedaStackAuthorizer, IVedaStackAccess {
    /// @notice The stack factories the administrator has named: the only writers of the record.
    mapping(address factory => bool named) public isFactory;
    /// @notice The overlay every published module must point at; zero while none is bound.
    address public overlay;

    mapping(address engine => bool active) public isActiveEngine;
    mapping(address forwarder => bool active) public isActiveForwarder;
    /// @notice Queues an active engine may still file on or cancel from: every published Queue until
    ///         the administrator retires it.
    mapping(address requestQueue => bool honored) public isHonoredQueue;
    /// @notice Stock solvers an active forwarding solver may still drive: every published solver until
    ///         the administrator retires it.
    mapping(address stockSolver => bool honored) public isHonoredSolver;
    /// @notice Overlays this registry created, which are the only ones it binds.
    mapping(address overlay => bool created) public isRegistryOverlay;

    event EngineAccessChanged(address indexed engine, bool active);
    event ForwarderAccessChanged(address indexed forwarder, bool active);
    event QueueHonoredChanged(address indexed requestQueue, bool honored);
    event SolverHonoredChanged(address indexed stockSolver, bool honored);
    event StackFactoryChanged(address indexed factory, bool named);
    event OverlayCreated(address indexed overlay, address indexed rolesAuthority);
    event OverlayChanged(address indexed oldOverlay, address indexed newOverlay);

    error InvalidOverlay(address overlay);
    error InvalidStackAccount(address account);
    error ModuleNotOnOverlay(address module, address expectedAuthority, address actualAuthority);
    error NotStackFactory(address caller);
    error OverlayRolesAuthorityMismatch(address overlay, address overlayRolesAuthority, address vaultAuthority);
    error StillPublished(address module);

    constructor(IBoringVault vault_, address baseAsset_) VedaVaultRegistry(vault_, baseAsset_) { }

    // ------------------------------------------------------------------
    // Anyone
    // ------------------------------------------------------------------

    /// @notice Creates the overlay for the RolesAuthority the BoringVault answers to now, or returns it
    ///         when it already exists.
    /// @dev Open to anyone: an overlay does nothing until the administrator points modules at it and
    ///      binds it. Its address depends only on this registry and that RolesAuthority, so it can be
    ///      computed with {predictOverlay} when the administrator's transactions are prepared.
    function createOverlay() external returns (address newOverlay) {
        address rolesAuthority = IAuth(address(vault)).authority();
        newOverlay = predictOverlay(rolesAuthority);
        if (newOverlay.code.length != 0) return newOverlay;
        newOverlay = address(
            new VedaAuthorityOverlay{ salt: _overlaySalt(rolesAuthority) }(
                IAuthority(rolesAuthority), IVedaStackAccess(address(this))
            )
        );
        isRegistryOverlay[newOverlay] = true;
        emit OverlayCreated(newOverlay, rolesAuthority);
    }

    /// @notice The address {createOverlay} gives the overlay for `rolesAuthority`.
    function predictOverlay(address rolesAuthority) public view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(VedaAuthorityOverlay).creationCode, abi.encode(rolesAuthority, address(this)))
        );
        return Create2.computeAddress(_overlaySalt(rolesAuthority), initCodeHash);
    }

    // ------------------------------------------------------------------
    // Vault administrator
    // ------------------------------------------------------------------

    /// @notice Names a stack factory as a writer of the record, or stops accepting one. The engines and
    ///         forwarders a factory recorded stay recorded when it is no longer named.
    /// @dev A named factory must report this registry as its registry and as its authorizer, so one
    ///      that reads some other registry cannot be named by mistake.
    function setFactory(address factory, bool named) external onlyVaultAdmin {
        if (named) {
            if (factory.code.length == 0) revert InvalidStackAccount(factory);
            IVedaStackFactoryWiring wiring = IVedaStackFactoryWiring(factory);
            if (wiring.registry() != address(this) || wiring.authorizer() != address(this)) {
                revert InvalidStackAccount(factory);
            }
        }
        isFactory[factory] = named;
        emit StackFactoryChanged(factory, named);
    }

    /// @notice Binds the overlay the published modules answer to, or unbinds it with zero.
    /// @dev The overlay must be one this registry created, for the RolesAuthority the BoringVault
    ///      answers to now, and the modules published now must already point at it.
    function setOverlay(address newOverlay) external onlyVaultAdmin {
        if (newOverlay != address(0)) {
            if (!isRegistryOverlay[newOverlay]) revert InvalidOverlay(newOverlay);
            _requireOverlayCurrent(newOverlay);
            if (version != 0) _requireOnOverlay(newOverlay, teller, queue, solver);
        }
        emit OverlayChanged(overlay, newOverlay);
        overlay = newOverlay;
    }

    /// @notice Stops honoring a Queue that is no longer published, or honors again one retired by
    ///         mistake.
    /// @dev Once a Queue is not honored, engines can neither file on it nor cancel from it: retire one
    ///      only after every engine's `openClaimsByQueue` for it is zero.
    function setQueueHonored(IBoringQueue requestQueue, bool honored) external onlyVaultAdmin {
        if (honored) {
            _validateContract(address(requestQueue));
            _requireWiring(address(requestQueue), address(vault), requestQueue.boringVault());
        } else if (requestQueue == queue) {
            revert StillPublished(address(requestQueue));
        }
        isHonoredQueue[address(requestQueue)] = honored;
        emit QueueHonoredChanged(address(requestQueue), honored);
    }

    /// @notice Stops honoring a stock solver that is no longer published, or honors again one retired
    ///         by mistake.
    /// @dev Once a stock solver is not honored, no forwarding solver fixed to it can settle a request.
    function setSolverHonored(IBoringSolver stockSolver, bool honored) external onlyVaultAdmin {
        if (honored) {
            _validateContract(address(stockSolver));
        } else if (stockSolver == solver) {
            revert StillPublished(address(stockSolver));
        }
        isHonoredSolver[address(stockSolver)] = honored;
        emit SolverHonoredChanged(address(stockSolver), honored);
    }

    /// @notice Clears an engine's or a forwarding solver's entry directly.
    /// @dev The administrator's own reduction, for an entry written by a factory that is no longer the
    ///      named one and whose pausers therefore cannot reach it. It only ever takes access away.
    function revokeAccess(address account) external onlyVaultAdmin {
        if (isActiveEngine[account]) {
            isActiveEngine[account] = false;
            emit EngineAccessChanged(account, false);
        }
        if (isActiveForwarder[account]) {
            isActiveForwarder[account] = false;
            emit ForwarderAccessChanged(account, false);
        }
    }

    // ------------------------------------------------------------------
    // Stack factory
    // ------------------------------------------------------------------

    /// @notice Records `engine` as active, or clears it.
    function setEngineAuthorized(address engine, bool authorized) external {
        _requireFactory();
        if (authorized && engine.code.length == 0) revert InvalidStackAccount(engine);
        isActiveEngine[engine] = authorized;
        emit EngineAccessChanged(engine, authorized);
    }

    /// @notice Records `forwarder` as active, or clears it.
    function setForwarderAuthorized(address forwarder, bool authorized) external {
        _requireFactory();
        if (authorized && forwarder.code.length == 0) revert InvalidStackAccount(forwarder);
        isActiveForwarder[forwarder] = authorized;
        emit ForwarderAccessChanged(forwarder, authorized);
    }

    // ------------------------------------------------------------------
    // Overlay rules
    // ------------------------------------------------------------------

    /// @notice The calls an Earn stack is allowed beyond what the RolesAuthority grants.
    /// @dev Three fixed rules, each a fixed set of functions on a module this registry names. The
    ///      BoringVault is never a target, whatever is published or recorded.
    function canStackCall(address user, address target, bytes4 functionSig) external view returns (bool) {
        if (target == address(vault)) return false;
        // Active engines may use the published Teller's bulk paths...
        if (target == address(teller)) {
            return (functionSig == ITeller.bulkDeposit.selector || functionSig == ITeller.bulkWithdraw.selector)
                && isActiveEngine[user];
        }
        // ...and file or cancel their own queued exits on an honored Queue.
        if (isHonoredQueue[target]) {
            return (functionSig == IBoringQueue.requestOnChainWithdraw.selector
                    || functionSig == IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector) && isActiveEngine[user];
        }
        // Active forwarding solvers may drive an honored stock solver.
        if (isHonoredSolver[target]) {
            return functionSig == IBoringSolver.boringRedeemSolve.selector && isActiveForwarder[user];
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev A published Queue and its stock solver are honored from publication. While an overlay is
    ///      bound, it must still pass through the vault's RolesAuthority, and every module of the new
    ///      tuple must already answer to it.
    function _beforePublish(ITeller newTeller, IBoringQueue newQueue, IBoringSolver newSolver) internal override {
        address overlay_ = overlay;
        if (overlay_ != address(0)) {
            _requireOverlayCurrent(overlay_);
            _requireOnOverlay(overlay_, newTeller, newQueue, newSolver);
        }
        if (address(newQueue) != address(0)) {
            if (!isHonoredQueue[address(newQueue)]) {
                isHonoredQueue[address(newQueue)] = true;
                emit QueueHonoredChanged(address(newQueue), true);
            }
            if (!isHonoredSolver[address(newSolver)]) {
                isHonoredSolver[address(newSolver)] = true;
                emit SolverHonoredChanged(address(newSolver), true);
            }
        }
    }

    /// @dev An overlay passes through one fixed RolesAuthority. Once the BoringVault answers to another,
    ///      modules behind the old overlay would follow a role table the vault has left.
    function _requireOverlayCurrent(address overlay_) private view {
        address overlayRolesAuthority = address(VedaAuthorityOverlay(overlay_).rolesAuthority());
        address vaultAuthority = IAuth(address(vault)).authority();
        if (overlayRolesAuthority != vaultAuthority) {
            revert OverlayRolesAuthorityMismatch(overlay_, overlayRolesAuthority, vaultAuthority);
        }
    }

    function _requireOnOverlay(address overlay_, ITeller teller_, IBoringQueue queue_, IBoringSolver solver_)
        private
        view
    {
        _requireAuthority(address(teller_), overlay_);
        if (address(queue_) != address(0)) {
            _requireAuthority(address(queue_), overlay_);
            _requireAuthority(address(solver_), overlay_);
        }
    }

    function _requireAuthority(address module, address expectedAuthority) private view {
        address actualAuthority = IAuth(module).authority();
        if (actualAuthority != expectedAuthority) {
            revert ModuleNotOnOverlay(module, expectedAuthority, actualAuthority);
        }
    }

    function _requireFactory() private view {
        if (!isFactory[msg.sender]) revert NotStackFactory(msg.sender);
    }

    function _overlaySalt(address rolesAuthority) private pure returns (bytes32) {
        return bytes32(uint256(uint160(rolesAuthority)));
    }
}
