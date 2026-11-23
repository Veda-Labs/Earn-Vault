// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../../interfaces/earn/IEarnVault.sol";
import {
    IVedaForwarderSteward,
    IVedaStackAuthorizer,
    IVedaTellerLister,
    IVedaVaultRegistry
} from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { ITIP403PolicyCreator } from "../../../../interfaces/external/tempo/ITIP403PolicyCreator.sol";
import {
    TIP403_REGISTRY_ADDRESS,
    WHITELIST_POLICY_TYPE
} from "../../../../interfaces/external/tempo/ITIP403Registry.sol";
import { IBoringQueue } from "../../../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../interfaces/external/veda/IBoringSolver.sol";
import { IAuth, IAuthority } from "../../../../interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../interfaces/external/veda/ITeller.sol";
import { EarnFactory } from "../../../core/EarnFactory.sol";
import { EarnFees } from "../../../core/EarnFees.sol";
import { EarnVault } from "../../../core/EarnVault.sol";
import { VedaForwardingSolver } from "../VedaForwardingSolver.sol";
import { VedaLockstepEngine } from "./VedaLockstepEngine.sol";
import { VedaForwardingSolverDeployer, VedaLockstepEngineDeployer } from "./VedaStackDeployers.sol";
import { VedaTellerAllowlist } from "./VedaTellerAllowlist.sol";

/// @title VedaStackFactory
/// @notice Builds complete Earn stacks on one BoringVault without a transaction from the vault's
///         administrator. One operator call deploys a {VedaLockstepEngine}, creates its EarnVault,
///         EarnShare and EarnFees through the canonical `EarnFactory`, deploys a forwarding solver when
///         the vault has a Queue, binds the engine, authorizes it, lists it on a Teller that admits by
///         account, and records the stack.
///
/// @dev WHAT THE VAULT'S ADMINISTRATOR TRUSTS, ONCE. The administrator names this factory on its
///      `authorizer` (a {VedaRoleGranter}, or a {VedaVaultAccessRegistry} behind a
///      {VedaAuthorityOverlay}) and on its `tellerLister` (a {VedaTellerLister}), whichever of the two
///      the vault needs, having reviewed this contract's code and wiring: each checks only that a
///      factory reports the right registry and itself. From then on this contract decides which
///      addresses receive the engine and forwarder authorization and a place on the Teller's list, so
///      it gives them only to contracts it built itself:
///      - an engine comes from the pinned engine deployer in this contract's own call, is owned by this
///        contract until it is bound, and is bound to the EarnVault the pinned `EarnFactory` just
///        produced for it. A canonical engine lets its owner bind any EarnVault, so checking an
///        engine's code would not be enough; this contract never authorizes an engine it did not own
///        from construction to binding;
///      - a forwarding solver comes from the pinned forwarder deployer, is fixed to one recorded
///        engine and the vault's published Queue, Teller and stock solver, and is owned by the
///        deployment-fixed `forwarderOwner`.
///      It is not the vault's owner, holds no role, and has no path to the BoringVault.
///
///      WHO CALLS IT. `operator` builds stacks, and never may be opened to everyone: an engine's
///      deposits and exits skip the Teller's share lock, so a stack's owner can enter before a rate
///      update and leave after it at the other holders' expense, and each stack picks its own EarnShare
///      transfer policy. The operator chooses each stack's owner, fees, controls, rate age bound and
///      transfer policy; this contract restricts none of them. That is the whole reach of a leaked
///      operator key: stacks of its choosing, with that timing exposure, which dilutes every holder of
///      the BoringVault, and further forwarding solvers for existing stacks, which settle nothing until
///      an engine's owner admits them. It never reaches a role, the registry, another stack's settings
///      or vault custody. The vault's pausers, and its administrator, can
///      revoke an engine or a forwarder and pause new registrations; pausing is the first response to a
///      leaked operator, since it stops every stack-building call at once. Only the administrator
///      reinstates, resumes, or replaces the operator. Pausers are the accounts the BoringVault's
///      authority allows to call the pausing function on this contract.
///
///      ONE CALL OR TWO. `createStack` does everything in one transaction. Where a chain's
///      per-transaction gas cap is below that, `deployEngine` then `finalizeStack` do the same in two;
///      between them the engine is owned by this contract, bound to nothing and authorized for nothing.
///      The canonical `EarnFactory` is open to anyone, so someone who sees a pending `finalizeStack`
///      can create the same core first and make it revert; the operator then finalizes under another
///      deployment id. Such a core is bound to nothing and holds nothing, and only the records here and
///      `StackCreated` say which stacks this factory built.
///
///      THE RECORDS ARE NOT THE PERMISSIONS. A status here says what this factory last did. The vault's
///      administrator can change a permission or the Teller's list directly, and a function the vault
///      lets anyone call stays callable by a revoked engine unless the Teller's list is what admits
///      it. {isEngineReady} reads the published modules live.
/// The factory's wiring never changes.
/// @custom:invariant address(registry) != address(0)
/// @custom:invariant address(earnFactory) != address(0) && forwarderOwner != address(0)
/// Mutating entry points are nonReentrant through the transient `_entered` flag.
/// @custom:reentrancy-guard _entered
contract VedaStackFactory {
    enum EngineStatus {
        None,
        /// Deployed by this factory and owned by it; bound to nothing and authorized for nothing.
        Pending,
        Active,
        Revoked,
        /// Deployed and never bound, then set aside for good: it can no longer be finalized.
        Discarded
    }

    enum ForwarderStatus {
        None,
        Active,
        Revoked
    }

    /// @notice Deployment-fixed wiring. See the matching immutables.
    struct Config {
        IVedaVaultRegistry registry;
        IVedaStackAuthorizer authorizer;
        IVedaTellerLister tellerLister;
        EarnFactory earnFactory;
        bytes32 earnFactoryCodeHash;
        VedaLockstepEngineDeployer engineDeployer;
        bytes32 engineDeployerCodeHash;
        VedaForwardingSolverDeployer forwarderDeployer;
        bytes32 forwarderDeployerCodeHash;
        address forwarderOwner;
        bool forwarderOwnerIsSteward;
        address forwarderTreasury;
        address operator;
    }

    /// @notice The engine's own settings; the vault's registry supplies everything else it needs.
    struct EngineParams {
        string name;
        string symbol;
        uint64 maxRateAge;
    }

    struct StackRecord {
        address earnVault;
        uint64 createdAtBlock;
        EngineStatus status;
        address earnShare;
        address earnFees;
        /// @dev The forwarding solver built with the stack; zero when the vault had no Queue then.
        address forwarder;
        address creator;
    }

    struct ForwarderRecord {
        address engine;
        ForwarderStatus status;
    }

    /// @notice The vault's registry: its modules, and who administers the vault.
    IVedaVaultRegistry public immutable registry;
    /// @notice Where this factory records an authorization: the role granter or the access registry.
    ///         Zero when the vault lets its engines and forwarding solvers call without one.
    IVedaStackAuthorizer public immutable authorizer;
    /// @notice What puts this factory's engines on the Teller's account allowlist. Zero when the vault's
    ///         Teller has no allowlist, or when engines are listed some other way before they are bound.
    IVedaTellerLister public immutable tellerLister;
    /// @notice The canonical core factory, pinned by address and by the code hash named at construction.
    EarnFactory public immutable earnFactory;
    bytes32 public immutable earnFactoryCodeHash;
    /// @notice The engine deployer, pinned the same way: every engine comes from this code.
    VedaLockstepEngineDeployer public immutable engineDeployer;
    bytes32 public immutable engineDeployerCodeHash;
    /// @notice The forwarder deployer, pinned the same way.
    VedaForwardingSolverDeployer public immutable forwarderDeployer;
    bytes32 public immutable forwarderDeployerCodeHash;
    /// @notice Owner of every forwarding solver built here: it allowlists the solvers that may trigger.
    address public immutable forwarderOwner;
    /// @notice Whether {forwarderOwner} is a {VedaForwarderSteward}, which approves the vault's solvers
    ///         on each forwarding solver as it is built. Otherwise a new forwarding solver settles
    ///         nothing until its owner approves a solver on it.
    bool public immutable forwarderOwnerIsSteward;
    /// @notice Where every forwarding solver built here sends rescued surplus.
    address public immutable forwarderTreasury;

    /// @notice The only account that builds stacks.
    address public operator;
    /// @notice While set, no engine, stack or forwarding solver is built or authorized.
    bool public registrationsPaused;

    /// @notice The engine built for each job id; zero when no build under that id has landed. A job id
    ///         builds one engine, so a build that is sent twice lands once.
    mapping(bytes32 jobId => address engine) public engineOf;
    mapping(address engine => StackRecord) private _stacks;
    mapping(address forwarder => ForwarderRecord) private _forwarders;
    address[] private _engines;

    bool private transient _entered;

    event EngineDeployed(address indexed engine, address indexed creator, bytes32 indexed jobId);
    event EngineDiscarded(address indexed engine, address indexed by);
    event StackCreated(
        address indexed engine,
        address indexed earnVault,
        address indexed earnShare,
        address earnFees,
        address forwarder,
        address owner,
        address creator
    );
    event ForwarderDeployed(address indexed forwarder, address indexed engine, address queue, address solver);
    event EngineAuthorizationChanged(address indexed engine, bool authorized, address indexed by);
    /// @notice A revocation removed one of the engine's two gates and not `gate`: the authorizer, whose
    ///         call reverted, or the Teller lister, whose Teller did not take the change.
    event EngineRevocationIncomplete(address indexed engine, address indexed gate);
    event ForwarderAuthorizationChanged(address indexed forwarder, bool authorized, address indexed by);
    event RegistrationsPauseChanged(bool paused, address indexed by);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event TransferPolicyCreated(uint64 indexed policyId, address indexed admin);

    error AmbiguousTransferPolicy(uint64 transferPolicyId, address newPolicyAdmin);
    error AuthorizerNotBound();
    error CodeHashMismatch(address account, bytes32 expected, bytes32 actual);
    error EmptyJobId();
    error EngineMustBeUnset(address engine);
    error EngineNotActive(address engine);
    error EngineNotPending(address engine);
    error EngineNotRevoked(address engine);
    error FactoryCannotBeOwner();
    error ForwarderNotActive(address forwarder);
    error ForwarderNotSeeded(address forwarder);
    error ForwarderNotRevoked(address forwarder);
    error InvalidEngineDeployment(address engine);
    error InvalidFactoryWiring(address account);
    error InvalidForwarderDeployment(address forwarder);
    error InvalidTransferPolicyAdmin(address admin);
    error JobAlreadyBuilt(bytes32 jobId, address engine);
    error NotAuthorizedOnVeda(address account, address target, bytes4 functionSig);
    error NotListedOnTeller(address engine, address teller);
    error NotOperator(address caller);
    error NotPauser(address caller);
    error NotVaultAdmin(address caller);
    error QueueUnavailable();
    error ReentrantCall();
    error RegistrationsPaused();
    error RevocationFailed(address account);
    error UnexpectedEarnVaultEngine(address earnVault, address expected, address actual);
    error ZeroAddress();

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        if (registrationsPaused) revert RegistrationsPaused();
        _;
    }

    modifier onlyVaultAdmin() {
        if (!registry.isVaultAdmin(msg.sender)) revert NotVaultAdmin(msg.sender);
        _;
    }

    /// @dev The vault's administrator, or an account the BoringVault's authority lets call this function
    ///      here. Pausing and revoking only ever reduce what this factory and its stacks can do.
    modifier onlyPauser() {
        if (!registry.isVaultAdmin(msg.sender)) {
            address authority = IAuth(address(registry.vault())).authority();
            if (authority.code.length == 0 || !IAuthority(authority).canCall(msg.sender, address(this), msg.sig)) {
                revert NotPauser(msg.sender);
            }
        }
        _;
    }

    constructor(Config memory config) {
        if (
            address(config.registry) == address(0) || address(config.earnFactory) == address(0)
                || address(config.engineDeployer) == address(0) || address(config.forwarderDeployer) == address(0)
                || config.forwarderOwner == address(0) || config.forwarderTreasury == address(0)
                || config.operator == address(0)
        ) revert ZeroAddress();
        _requireCode(address(config.registry));
        // Either may be absent: a vault can gate its engines by role, by the Teller's list, or by both.
        if (address(config.authorizer) != address(0)) _requireCode(address(config.authorizer));
        if (address(config.tellerLister) != address(0)) _requireCode(address(config.tellerLister));
        if (config.forwarderOwnerIsSteward) {
            _requireCode(config.forwarderOwner);
            // A steward cannot move tokens it holds, so surplus rescued to it would be stranded.
            if (config.forwarderTreasury == config.forwarderOwner) {
                revert InvalidFactoryWiring(config.forwarderTreasury);
            }
        }
        // Each pinned contract is named by address and by the code hash its deployer states, which is
        // what a reviewer compares with the release. The hashes cannot be wrong for these addresses.
        _requireCodeHash(address(config.earnFactory), config.earnFactoryCodeHash);
        _requireCodeHash(address(config.engineDeployer), config.engineDeployerCodeHash);
        _requireCodeHash(address(config.forwarderDeployer), config.forwarderDeployerCodeHash);

        registry = config.registry;
        authorizer = config.authorizer;
        tellerLister = config.tellerLister;
        earnFactory = config.earnFactory;
        earnFactoryCodeHash = config.earnFactoryCodeHash;
        engineDeployer = config.engineDeployer;
        engineDeployerCodeHash = config.engineDeployerCodeHash;
        forwarderDeployer = config.forwarderDeployer;
        forwarderDeployerCodeHash = config.forwarderDeployerCodeHash;
        forwarderOwner = config.forwarderOwner;
        forwarderOwnerIsSteward = config.forwarderOwnerIsSteward;
        forwarderTreasury = config.forwarderTreasury;
        operator = config.operator;
        emit OperatorChanged(address(0), config.operator);
    }

    // ------------------------------------------------------------------
    // Operator: build stacks
    // ------------------------------------------------------------------

    /// @notice Builds a whole stack in one call and hands it to `core.owner`.
    /// @param jobId The caller's own nonzero id for this build. It builds one engine: a second call
    ///        under the same id reverts, and {engineOf} says which engine the first one built. The id
    ///        commits to no settings, so a caller told its job was already built checks that engine's
    ///        settings and stack owner before adopting it. It is separate from `core.deploymentId`,
    ///        which may have to change when a finalize is retried, and from any other factory's ids.
    /// @param engineParams The engine's name, symbol and rate age bound; EarnShare takes its name from them.
    /// @param core The canonical `EarnFactory` parameters. `core.engine` must be zero: this factory
    ///        supplies the engine. `core.owner` becomes the EarnVault's operator and the engine's owner.
    /// @param newTransferPolicyAdmin Zero to use `core.transferPolicyId` as given (zero there means no
    ///        restriction). Nonzero to create a new TIP-403 whitelist administered by that address and
    ///        attach it; `core.transferPolicyId` must then be zero.
    function createStack(
        bytes32 jobId,
        EngineParams calldata engineParams,
        EarnFactory.DeployParams calldata core,
        address newTransferPolicyAdmin
    ) external onlyOperator nonReentrant returns (address engine, address earnVault, address earnShare) {
        engine = _deployEngine(jobId, engineParams);
        (earnVault, earnShare) = _finalizeStack(engine, core, newTransferPolicyAdmin);
    }

    /// @notice First half of a stack built in two transactions: deploys the engine, owned by this
    ///         factory, bound to nothing and authorized for nothing until {finalizeStack}.
    /// @dev `jobId` as in {createStack}. {finalizeStack} is safe to send twice by itself: it accepts
    ///      a pending engine once.
    function deployEngine(bytes32 jobId, EngineParams calldata engineParams)
        external
        onlyOperator
        nonReentrant
        returns (address engine)
    {
        engine = _deployEngine(jobId, engineParams);
    }

    /// @notice Second half: builds the rest of the stack around an engine from {deployEngine}.
    /// @dev Parameters as in {createStack}.
    function finalizeStack(address engine, EarnFactory.DeployParams calldata core, address newTransferPolicyAdmin)
        external
        onlyOperator
        nonReentrant
        returns (address earnVault, address earnShare)
    {
        (earnVault, earnShare) = _finalizeStack(engine, core, newTransferPolicyAdmin);
    }

    /// @notice Builds and authorizes a forwarding solver for an active engine against the vault's
    ///         published Queue, Teller and stock solver: for a stack built before the vault had a Queue,
    ///         or after a publication changed the Queue, its stock solver or the Teller, each of which a
    ///         forwarding solver fixes at construction.
    /// @dev The engine's owner must still authorize the returned forwarder on the engine itself; this
    ///      factory stopped being that owner when it bound the engine. Until both steps are done,
    ///      requests filed on a newly published Queue cannot be settled. A forwarder is only ever built
    ///      for the tuple published now, so the modules a replaced Queue's open requests settle through
    ///      must stay live until those requests are closed. `stack(engine).forwarder` stays the one
    ///      built with the stack, so this call cannot rewrite a stack's record; `ForwarderDeployed` lists
    ///      every forwarder, and the engine's `authorizedForwarder` says which ones its owner admitted.
    function deployForwarder(address engine) external onlyOperator nonReentrant returns (address forwarder) {
        if (_stacks[engine].status != EngineStatus.Active) revert EngineNotActive(engine);
        _requireAuthorizerBound();
        forwarder = _deployForwarder(engine);
        if (forwarder == address(0)) revert QueueUnavailable();
        _authorizeForwarder(forwarder);
    }

    // ------------------------------------------------------------------
    // Pausers: reduce
    // ------------------------------------------------------------------

    /// @notice Takes an engine's authorization and its place on the Teller's list away: its deposits
    ///         and immediate exits stop until the vault's administrator reinstates it, and so do its new
    ///         queued requests and cancellations unless the vault lets anyone call those. Requests
    ///         already queued can still be settled, except on a Queue that applies the Teller's list,
    ///         which settles nothing for a delisted engine and lets a waiting request pass its deadline.
    ///         For incidents only: the stack's users cannot exit instantly while it lasts.
    /// @dev The authorization and the listing are removed independently, so that one that cannot be
    ///      removed never keeps the other in place, and `EngineRevocationIncomplete` names a gate that
    ///      was not removed. A lister that accepts the call records the engine as delisted even when
    ///      the Teller does not take the change, so the revocation stands and anyone can finish it
    ///      there. The call reverts only when nothing was removed or recorded: with the authorizer's
    ///      own reason when it gave one. Where the vault lets anyone call the Teller, an engine stays
    ///      usable until its listing is actually gone, and with no lister it keeps working.
    function revokeEngine(address engine) external onlyPauser nonReentrant {
        StackRecord storage record = _stacks[engine];
        if (record.status != EngineStatus.Active) revert EngineNotActive(engine);
        record.status = EngineStatus.Revoked;

        bool recorded;
        if (address(tellerLister) != address(0)) {
            try tellerLister.setEngineListed(engine, false) returns (bool applied) {
                recorded = true;
                if (!applied) emit EngineRevocationIncomplete(engine, address(tellerLister));
            } catch {
                emit EngineRevocationIncomplete(engine, address(tellerLister));
            }
        }
        if (address(authorizer) != address(0)) {
            try authorizer.setEngineAuthorized(engine, false) {
                recorded = true;
            } catch (bytes memory reason) {
                // With nothing else removed, this is the reason the revocation failed.
                if (!recorded) _revertWith(reason);
                emit EngineRevocationIncomplete(engine, address(authorizer));
            }
        }
        if (!recorded) revert RevocationFailed(engine);
        emit EngineAuthorizationChanged(engine, false, msg.sender);
    }

    /// @notice Takes a forwarding solver's authorization away, so it can no longer drive the stock solver.
    /// @dev Reverts on a factory without an authorizer, which granted the forwarder nothing to take away.
    function revokeForwarder(address forwarder) external onlyPauser nonReentrant {
        ForwarderRecord storage record = _forwarders[forwarder];
        if (record.status != ForwarderStatus.Active) revert ForwarderNotActive(forwarder);
        if (address(authorizer) == address(0)) revert RevocationFailed(forwarder);
        record.status = ForwarderStatus.Revoked;
        authorizer.setForwarderAuthorized(forwarder, false);
        emit ForwarderAuthorizationChanged(forwarder, false, msg.sender);
    }

    /// @notice Stops every stack-building call until the vault's administrator resumes them.
    function pauseRegistrations() external onlyPauser {
        registrationsPaused = true;
        emit RegistrationsPauseChanged(true, msg.sender);
    }

    /// @notice Sets a pending engine aside for good, so that it can never be finalized: for an engine
    ///         deployed by an operator key that is no longer trusted. It is bound to nothing and
    ///         authorized for nothing, and its job id stays used.
    function discardEngine(address engine) external onlyPauser nonReentrant {
        StackRecord storage record = _stacks[engine];
        if (record.status != EngineStatus.Pending) revert EngineNotPending(engine);
        record.status = EngineStatus.Discarded;
        emit EngineDiscarded(engine, msg.sender);
    }

    // ------------------------------------------------------------------
    // Vault administrator: restore
    // ------------------------------------------------------------------

    /// @notice Gives a revoked engine its authorization back.
    function reinstateEngine(address engine) external onlyVaultAdmin nonReentrant {
        StackRecord storage record = _stacks[engine];
        if (record.status != EngineStatus.Revoked) revert EngineNotRevoked(engine);
        _requireAuthorizerBound();
        record.status = EngineStatus.Active;
        _authorizeEngine(engine);
    }

    /// @notice Gives a revoked forwarding solver its authorization back.
    function reinstateForwarder(address forwarder) external onlyVaultAdmin nonReentrant {
        ForwarderRecord storage record = _forwarders[forwarder];
        if (record.status != ForwarderStatus.Revoked) revert ForwarderNotRevoked(forwarder);
        _requireAuthorizerBound();
        record.status = ForwarderStatus.Active;
        _authorizeForwarder(forwarder);
    }

    function resumeRegistrations() external onlyVaultAdmin {
        registrationsPaused = false;
        emit RegistrationsPauseChanged(false, msg.sender);
    }

    /// @notice Replaces the operator, for example after a key rotation.
    function setOperator(address newOperator) external onlyVaultAdmin {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The record of the stack built around `engine`; a zero status means this factory did not
    ///         build it.
    function stack(address engine) external view returns (StackRecord memory) {
        return _stacks[engine];
    }

    /// @notice The engine a forwarding solver built here settles, and whether it is authorized.
    function forwarderRecord(address forwarder) external view returns (ForwarderRecord memory) {
        return _forwarders[forwarder];
    }

    /// @notice Engines this factory has deployed, pending ones included.
    function engineCount() external view returns (uint256) {
        return _engines.length;
    }

    function engineAt(uint256 index) external view returns (address) {
        return _engines[index];
    }

    /// @notice Whether the vault's administrator has named this factory on its authorizer and on its
    ///         Teller lister, whichever of them it has. Stack-building reverts while it has not.
    function isAuthorizerBound() public view returns (bool) {
        return (address(authorizer) == address(0) || authorizer.isFactory(address(this)))
            && (address(tellerLister) == address(0) || tellerLister.isFactory(address(this)));
    }

    /// @notice Whether `engine` is an active stack of this factory that the vault's published modules
    ///         would serve right now: allowed to call them, and admitted by the Teller's list.
    /// @dev Read live, unlike a stack's status, which only says what this factory last did. A Teller
    ///      whose list is not enforced, or cannot be read, admits every account. It does not cover the
    ///      registry's deposit halt, which is read from the registry, a
    ///      paused Teller, a deposit cap, the stack's own EarnVault controls, or whether the Queue
    ///      applies the Teller's list.
    function isEngineReady(address engine) external view returns (bool) {
        if (_stacks[engine].status != EngineStatus.Active) return false;
        (address target,) = _firstRefusedCall(engine);
        return target == address(0) && _isListed(engine, address(registry.teller()));
    }

    /// @notice Whether the wiring and permissions a queued exit needs are in place for `forwarder` and
    ///         `solver`: it is an active forwarding solver of this factory, fixed to the Queue, stock
    ///         solver and Teller published now, admitted by its engine, allowed on the stock solver,
    ///         and has `solver` approved; and a Teller that keeps a list admits the stock solver, and
    ///         the engine where the Queue applies that list.
    /// @dev Read live. The queued path is a backup that may go unused for a long time, so this is how
    ///      to learn that it is miswired before it is needed. True does not mean a settlement would
    ///      succeed: it does not cover the stock solver's own permissions on the Queue and the Teller,
    ///      a pause, liquidity or a deficit nobody funds, the base asset's transfer policy, or a
    ///      request's maturity and deadline. False does not mean broken for a forwarder fixed to a
    ///      replaced Queue that still has open requests.
    function isForwarderReady(address forwarder, address solver) external view returns (bool) {
        ForwarderRecord memory record = _forwarders[forwarder];
        if (record.status != ForwarderStatus.Active) return false;
        VedaForwardingSolver built = VedaForwardingSolver(forwarder);
        address queue = address(registry.queue());
        address stockSolver = address(registry.solver());
        address teller = address(registry.teller());
        if (
            queue == address(0) || address(built.queue()) != queue || address(built.boringSolver()) != stockSolver
                || built.teller() != teller
        ) return false;
        if (!VedaLockstepEngine(record.engine).authorizedForwarder(forwarder) || !built.isAuthorizedSolver(solver)) {
            return false;
        }
        if (!_canCall(forwarder, stockSolver, IBoringSolver.boringRedeemSolve.selector)) return false;
        (bool checked, bool allowed) = VedaTellerAllowlist.tryIsWithdrawAllowed(teller, stockSolver);
        if (checked && !allowed) return false;
        (bool queueChecks, address queueTeller) = VedaTellerAllowlist.tryQueueTeller(queue);
        if (queueChecks && queueTeller != address(0)) {
            (checked, allowed) = VedaTellerAllowlist.tryIsWithdrawAllowed(queueTeller, record.engine);
            if (checked && !allowed) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _deployEngine(bytes32 jobId, EngineParams calldata engineParams) private returns (address engine) {
        if (jobId == bytes32(0)) revert EmptyJobId();
        address built = engineOf[jobId];
        if (built != address(0)) revert JobAlreadyBuilt(jobId, built);
        engine = engineDeployer.deploy(
            registry, address(this), engineParams.maxRateAge, engineParams.name, engineParams.symbol
        );
        // The pinned deployer always returns a fresh engine wired like this; a mismatch means the
        // deployer is not the one this factory was meant to pin, and nothing is recorded.
        if (
            engine.code.length == 0 || _stacks[engine].status != EngineStatus.None
                || address(VedaLockstepEngine(engine).vaultRegistry()) != address(registry)
                || VedaLockstepEngine(engine).owner() != address(this)
                || VedaLockstepEngine(engine).earnVault() != address(0)
        ) revert InvalidEngineDeployment(engine);

        StackRecord storage record = _stacks[engine];
        record.status = EngineStatus.Pending;
        record.creator = msg.sender;
        engineOf[jobId] = engine;
        _engines.push(engine);
        emit EngineDeployed(engine, msg.sender, jobId);
    }

    function _finalizeStack(address engine, EarnFactory.DeployParams calldata core, address newTransferPolicyAdmin)
        private
        returns (address earnVault, address earnShare)
    {
        StackRecord storage record = _stacks[engine];
        if (record.status != EngineStatus.Pending) revert EngineNotPending(engine);
        if (core.engine != address(0)) revert EngineMustBeUnset(core.engine);
        // An engine left with this factory as its owner could never be administered.
        if (core.owner == address(this)) revert FactoryCannotBeOwner();
        _requireAuthorizerBound();
        record.status = EngineStatus.Active;

        EarnFactory.DeployParams memory params = core;
        params.engine = engine;
        if (newTransferPolicyAdmin != address(0)) {
            if (core.transferPolicyId != 0) {
                revert AmbiguousTransferPolicy(core.transferPolicyId, newTransferPolicyAdmin);
            }
            // This contract cannot administer a policy, so a policy it administered would be frozen empty.
            if (newTransferPolicyAdmin == address(this)) revert InvalidTransferPolicyAdmin(newTransferPolicyAdmin);
            params.transferPolicyId = ITIP403PolicyCreator(TIP403_REGISTRY_ADDRESS)
                .createPolicy(newTransferPolicyAdmin, WHITELIST_POLICY_TYPE);
            emit TransferPolicyCreated(params.transferPolicyId, newTransferPolicyAdmin);
        }

        // The canonical core, around this engine and no other.
        EarnVault earnVault_;
        EarnFees earnFees_;
        (earnShare, earnVault_, earnFees_) = earnFactory.deploy(params);
        earnVault = address(earnVault_);
        address boundEngine = IEarnVault(earnVault).engine();
        if (boundEngine != engine) revert UnexpectedEarnVaultEngine(earnVault, engine, boundEngine);

        // While this factory still owns the engine: trust the forwarder, bind the EarnVault the
        // canonical factory just produced, and hand the engine to its final owner in the same call.
        address forwarder = _deployForwarder(engine);
        if (forwarder != address(0)) VedaLockstepEngine(engine).setAuthorizedForwarder(forwarder, true);
        VedaLockstepEngine(engine).initializeEarnVault(earnVault, core.owner);

        record.earnVault = earnVault;
        record.createdAtBlock = uint64(block.number);
        record.earnShare = earnShare;
        record.earnFees = address(earnFees_);
        record.forwarder = forwarder;
        record.creator = msg.sender;

        _authorizeEngine(engine);
        if (forwarder != address(0)) _authorizeForwarder(forwarder);
        emit StackCreated(engine, earnVault, earnShare, address(earnFees_), forwarder, core.owner, msg.sender);
    }

    /// @dev Builds a forwarding solver for `engine` against the published Queue, Teller and stock
    ///      solver and records it, or returns zero when the vault is immediate-only.
    function _deployForwarder(address engine) private returns (address forwarder) {
        IBoringQueue queue = registry.queue();
        if (address(queue) == address(0)) return address(0);
        IBoringSolver solver = registry.solver();
        address teller = address(registry.teller());
        forwarder = forwarderDeployer.deploy(solver, queue, teller, engine, forwarderOwner, forwarderTreasury);
        // The pinned deployer always returns a fresh forwarding solver wired like this.
        if (forwarder.code.length == 0 || _forwarders[forwarder].status != ForwarderStatus.None) {
            revert InvalidForwarderDeployment(forwarder);
        }
        VedaForwardingSolver built = VedaForwardingSolver(forwarder);
        if (
            address(built.engine()) != engine || address(built.queue()) != address(queue)
                || address(built.boringSolver()) != address(solver) || built.teller() != teller
                || built.owner() != forwarderOwner || built.treasury() != forwarderTreasury
        ) revert InvalidForwarderDeployment(forwarder);
        _forwarders[forwarder] = ForwarderRecord({ engine: engine, status: ForwarderStatus.Active });
        // A steward approves the vault's solvers now, so the forwarder can settle from its first
        // request. A forwarder no listed solver could trigger is not built.
        if (forwarderOwnerIsSteward && IVedaForwarderSteward(forwarderOwner).seed(forwarder) == 0) {
            revert ForwarderNotSeeded(forwarder);
        }
        emit ForwarderDeployed(forwarder, engine, address(queue), address(solver));
    }

    /// @dev Authorizes and lists an engine, then proves both worked: the engine must now be allowed on
    ///      the published Teller's bulk paths and, when the vault has a Queue, on its request and
    ///      cancellation, and a Teller that checks accounts must have the engine on its list. A stack
    ///      whose permissions are not in place is never reported as built.
    function _authorizeEngine(address engine) private {
        if (address(authorizer) != address(0)) authorizer.setEngineAuthorized(engine, true);
        if (address(tellerLister) != address(0)) tellerLister.setEngineListed(engine, true);

        (address target, bytes4 functionSig) = _firstRefusedCall(engine);
        if (target != address(0)) revert NotAuthorizedOnVeda(engine, target, functionSig);
        address teller = address(registry.teller());
        if (!_isListed(engine, teller)) revert NotListedOnTeller(engine, teller);
        emit EngineAuthorizationChanged(engine, true, msg.sender);
    }

    /// @dev The first of an engine's calls on the published modules that the module's own authority
    ///      refuses, or zero when it allows them all. Where a function is open to everyone this proves
    ///      nothing about the engine, which is why {_isListed} is checked beside it.
    function _firstRefusedCall(address engine) private view returns (address target, bytes4 functionSig) {
        address teller = address(registry.teller());
        if (!_canCall(engine, teller, ITeller.bulkDeposit.selector)) return (teller, ITeller.bulkDeposit.selector);
        if (!_canCall(engine, teller, ITeller.bulkWithdraw.selector)) return (teller, ITeller.bulkWithdraw.selector);
        address queue = address(registry.queue());
        if (queue != address(0)) {
            if (!_canCall(engine, queue, IBoringQueue.requestOnChainWithdraw.selector)) {
                return (queue, IBoringQueue.requestOnChainWithdraw.selector);
            }
            if (!_canCall(engine, queue, IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector)) {
                return (queue, IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector);
            }
        }
    }

    /// @dev Whether the Teller's account allowlist admits `engine` as a share recipient and as a share
    ///      owner. A Teller without an allowlist admits every account.
    function _isListed(address engine, address teller) private view returns (bool) {
        (bool depositChecked, bool depositAllowed) = VedaTellerAllowlist.tryIsDepositAllowed(teller, engine);
        (bool withdrawChecked, bool withdrawAllowed) = VedaTellerAllowlist.tryIsWithdrawAllowed(teller, engine);
        return (!depositChecked || depositAllowed) && (!withdrawChecked || withdrawAllowed);
    }

    /// @dev Authorizes a forwarding solver this factory built and proves it may drive its stock solver.
    function _authorizeForwarder(address forwarder) private {
        if (address(authorizer) != address(0)) authorizer.setForwarderAuthorized(forwarder, true);
        _requireCanCall(
            forwarder, address(VedaForwardingSolver(forwarder).boringSolver()), IBoringSolver.boringRedeemSolve.selector
        );
        emit ForwarderAuthorizationChanged(forwarder, true, msg.sender);
    }

    function _requireCanCall(address account, address target, bytes4 functionSig) private view {
        if (!_canCall(account, target, functionSig)) revert NotAuthorizedOnVeda(account, target, functionSig);
    }

    function _canCall(address account, address target, bytes4 functionSig) private view returns (bool) {
        address authority = IAuth(target).authority();
        return authority.code.length != 0 && IAuthority(authority).canCall(account, target, functionSig);
    }

    /// @dev Reverts with `reason` as the callee gave it.
    function _revertWith(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    function _requireAuthorizerBound() private view {
        if (!isAuthorizerBound()) revert AuthorizerNotBound();
    }

    function _requireCode(address account) private view {
        if (account.code.length == 0) revert InvalidFactoryWiring(account);
    }

    function _requireCodeHash(address account, bytes32 expected) private view {
        _requireCode(account);
        bytes32 actual = account.codehash;
        if (actual != expected) revert CodeHashMismatch(account, expected, actual);
    }
}
