// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IVedaVaultRegistry } from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAccountant } from "../../../../interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../interfaces/external/veda/IBoringVault.sol";
import { IAuth, IAuthority, IBoringVaultCustody } from "../../../../interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../interfaces/external/veda/ITeller.sol";
import { VedaAccountantFreshness } from "./VedaAccountantFreshness.sol";
import { VedaTellerAllowlist } from "./VedaTellerAllowlist.sol";

/// @title VedaVaultRegistry
/// @notice Per-vault source of truth for the Teller, optional tracking Queue with its stock solver, and
///         Accountant attached to one BoringVault. Every {VedaLockstepEngine} on the vault reads it on
///         every call, so one publication takes effect on all of them in the same block.
/// @dev Ownerless and immutable to one BoringVault and base asset. Only the vault's administrator
///      publishes: the BoringVault's owner, or the owner of the BoringVault's current authority. Both
///      already hold full custody power over the vault, so the registry adds no new trust root, and both
///      are read live, so the registry follows the vault through an ownership or authority change.
///
///      LOCKSTEP. There is no per-engine activation step, so publication runs the checks an engine used
///      to run before activating a tuple: wiring, Queue tracking, a rate report that is readable and no
///      older than the caller allows, and a safe rate inside the caller's bounds. It also requires that
///      the Teller can already mint and burn the vault's shares, because a Teller that cannot would stop
///      every stack in the same block. Those checks catch mixed wiring, a stale report, an unexpected
///      rate jump, a Teller without its vault permissions and, where the Teller keeps an account
///      allowlist, a Queue bound to another Teller's list or a stock solver that is not on it. They
///      cannot show that a module's bytecode is benign, that the Earn stacks hold their permissions or
///      their places on the new Teller's list, or that the caller chose tight bounds; those stay with
///      the review of the publication. Bounds as wide as `1` and the maximum waive the rate check, and
///      a rate that jumps inside the bounds is priced by every stack at once, fees included.
///
///      DEPOSIT HALT. Every engine also reads here whether its own deposits are halted. The vault's
///      pausers set that for one engine and only the administrator clears it. It is the vault's side of
///      a stack's deposit pause, for a stack whose owner will not or cannot pause it: the engine's
///      deposits stop and every exit keeps working. It binds because an engine's code is fixed; it
///      does nothing for an account that reaches the Teller without an engine. Where the vault lets
///      anyone call the Teller's bulk deposit, anyone can still mint shares straight to a halted
///      engine and have its EarnVault absorb them, so there the halt stops the stack's own deposit
///      path and nothing more: only a Teller that restricts who may call bulk deposit makes it a stop.
contract VedaVaultRegistry is IVedaVaultRegistry {
    IBoringVault public immutable vault;
    address public immutable baseAsset;

    ITeller public teller;
    uint64 public version;
    IBoringQueue public queue;
    IAccountant public accountant;
    IBoringSolver public solver;

    /// @notice Engines whose deposits the vault's pausers have stopped. Their exits are unaffected.
    mapping(address engine => bool halted) public depositsHalted;

    event DepositsHaltChanged(address indexed engine, bool halted, address indexed by);
    event VedaVaultPeripheryPublished(
        uint64 indexed version,
        address indexed teller,
        address indexed queue,
        address accountant,
        address solver,
        uint256 validatedRate
    );

    error InvalidMaxReportAge();
    error InvalidRateTimestamp(uint256 updatedAt, uint256 currentTime);
    error InvalidVedaPeriphery(address account);
    error InvalidVedaPeripheryWiring(address component, address expected, address actual);
    error InvalidVedaRateBounds(uint256 minRate, uint256 maxRate);
    error SolverNotListedOnTeller(address solver, address teller);
    error NotPauser(address caller);
    error NotVaultAdmin(address caller);
    error QueueSolverMismatch(address queue, address solver);
    error QueueTellerMismatch(address queue, address expected, address actual);
    error QueueTrackingDisabled(address queue);
    error StaleAccountantRate(uint256 updatedAt, uint256 currentTime, uint256 maxAge);
    error TellerNotAuthorizedOnVault(address teller, bytes4 functionSig);
    error UnsupportedAccountantFreshness(address accountant);
    error VedaRateOutOfBounds(uint256 rate, uint256 minRate, uint256 maxRate);
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
    /// @dev Takes effect on every engine in this call. `newQueue` and `newSolver` are both zero for
    ///      immediate-only operation, or both set. `minRate` and `maxRate` bound the new Accountant's safe
    ///      rate and `maxReportAge` the age of its latest report, so a publication scheduled against one
    ///      rate or report cannot execute against another.
    function publish(
        ITeller newTeller,
        IBoringQueue newQueue,
        IAccountant newAccountant,
        IBoringSolver newSolver,
        uint256 minRate,
        uint256 maxRate,
        uint64 maxReportAge
    ) external onlyVaultAdmin {
        _validateWiring(newTeller, newQueue, newAccountant, newSolver);
        uint256 validatedRate = _validateRate(newAccountant, minRate, maxRate, maxReportAge);
        _beforePublish(newTeller, newQueue, newSolver);

        teller = newTeller;
        queue = newQueue;
        accountant = newAccountant;
        solver = newSolver;
        uint64 newVersion = ++version;
        emit VedaVaultPeripheryPublished(
            newVersion, address(newTeller), address(newQueue), address(newAccountant), address(newSolver), validatedRate
        );
    }

    /// @notice Stops `engine`'s deposits. Its immediate and queued exits, cancellations and
    ///         settlements keep working.
    /// @dev The vault's administrator, or an account the BoringVault's authority lets call this
    ///      function here. Halting only reduces what an engine can do, and it is not undone by the
    ///      engine's owner. Any address may be named; only a {VedaLockstepEngine} on this registry
    ///      reads its own entry.
    function haltDeposits(address engine) external {
        if (!isVaultAdmin(msg.sender)) {
            (bool hasAuthority, address authority) = _tryReadAddress(address(vault), IAuth.authority.selector);
            if (
                !hasAuthority || authority.code.length == 0
                    || !IAuthority(authority).canCall(msg.sender, address(this), msg.sig)
            ) revert NotPauser(msg.sender);
        }
        depositsHalted[engine] = true;
        emit DepositsHaltChanged(engine, true, msg.sender);
    }

    /// @notice Lets `engine` take deposits again.
    function resumeDeposits(address engine) external onlyVaultAdmin {
        depositsHalted[engine] = false;
        emit DepositsHaltChanged(engine, false, msg.sender);
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

    /// @dev Extension point for a registry that must check or record more about a publication.
    function _beforePublish(ITeller newTeller, IBoringQueue newQueue, IBoringSolver newSolver) internal virtual { }

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
            _requireAllowlistWiring(address(newTeller), address(newQueue), address(newSolver));
        }
        _requireWiring(address(newAccountant), expectedVault, newAccountant.vault());
        _requireWiring(address(newAccountant), baseAsset, newAccountant.base());
    }

    function _validateRate(IAccountant newAccountant, uint256 minRate, uint256 maxRate, uint64 maxReportAge)
        private
        view
        returns (uint256 validatedRate)
    {
        if (minRate == 0 || minRate > maxRate) revert InvalidVedaRateBounds(minRate, maxRate);
        if (maxReportAge == 0) revert InvalidMaxReportAge();

        // Every engine reads this Accountant's report age before a deposit and before crystallizing fees,
        // so an Accountant whose report cannot be read, is missing, is dated in the future, or is older
        // than the caller allows is refused.
        (bool supported, uint64 updatedAt) = VedaAccountantFreshness.tryRateUpdatedAt(newAccountant);
        if (!supported) revert UnsupportedAccountantFreshness(address(newAccountant));
        uint256 currentTime = block.timestamp;
        if (updatedAt == 0 || updatedAt > currentTime) revert InvalidRateTimestamp(updatedAt, currentTime);
        if (currentTime - updatedAt > maxReportAge) revert StaleAccountantRate(updatedAt, currentTime, maxReportAge);

        validatedRate = newAccountant.getRateInQuoteSafe(baseAsset);
        if (validatedRate < minRate || validatedRate > maxRate) {
            revert VedaRateOutOfBounds(validatedRate, minRate, maxRate);
        }
    }

    /// @dev Every deposit mints through the Teller and every immediate exit burns through it, so the
    ///      Teller must already be the vault's owner or be allowed `enter` and `exit` by its authority.
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

    /// @dev Where the Teller keeps an account allowlist: a Queue that checks one must check this
    ///      Teller's, or it would settle against a list the vault's engines are not on, and the stock
    ///      solver must be on it, because the solver redeems every settled request through the Teller.
    ///      Modules that expose neither reading are taken to have no allowlist.
    function _requireAllowlistWiring(address newTeller, address newQueue, address newSolver) private view {
        (bool queueChecks, address queueTeller) = VedaTellerAllowlist.tryQueueTeller(newQueue);
        if (queueChecks && queueTeller != address(0) && queueTeller != newTeller) {
            revert QueueTellerMismatch(newQueue, newTeller, queueTeller);
        }
        (bool tellerChecks, bool solverAllowed) = VedaTellerAllowlist.tryIsWithdrawAllowed(newTeller, newSolver);
        if (tellerChecks && !solverAllowed) revert SolverNotListedOnTeller(newSolver, newTeller);
    }

    function _validateContract(address account) internal view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert InvalidVedaPeriphery(account);
    }

    function _requireWiring(address component, address expected, address actual) internal pure {
        if (actual != expected) revert InvalidVedaPeripheryWiring(component, expected, actual);
    }
}
