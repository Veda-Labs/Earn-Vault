// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IVedaForwarderSteward } from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { VedaForwardingSolver } from "../VedaForwardingSolver.sol";

/// @title VedaForwarderSteward
/// @notice Owns the forwarding solvers a {VedaStackFactory} builds and keeps one list of the solvers
///         allowed to trigger them, so a new forwarding solver needs no transaction from its owner
///         before it can settle.
/// @dev A {VedaForwardingSolver} lets only its owner approve a solver, and ownership moves in two
///      steps, so a factory cannot approve one and hand the forwarder on in the same call. This
///      contract is the owner from construction instead. Its own owner, typically a Safe, edits the
///      list here once; applying the list to a forwarder is open to anyone, because it only ever
///      moves that forwarder toward the list:
///      - {seed} approves every listed solver, which the factory calls as it builds a forwarder;
///      - {prune} removes named accounts that are not on the list, after a solver is retired.
///      A solver can trigger settlement and nothing else: a forwarding solver pays each request's
///      owner through its engine and keeps any surplus for its treasury. The owner keeps the
///      forwarders' remaining owner functions through {setForwarderTreasury}, {rescue},
///      {releaseForwarder} and {acceptForwarder}. This contract cannot move tokens it holds, so it
///      must never be a forwarder's treasury. It keeps no list of forwarders: applying a change to
///      all of them means naming each one, from the factory's `ForwarderDeployed` events.
contract VedaForwarderSteward is Ownable2Step, IVedaForwarderSteward {
    /// @notice Bound on the list, so seeding a forwarder stays cheap inside a stack build.
    uint256 public constant MAX_SOLVERS = 8;

    address[] private _solvers;
    /// @notice Whether `account` is on the list of solvers every forwarder should approve.
    mapping(address account => bool listed) public isSolver;

    event SolverChanged(address indexed solver, bool listed);
    event ForwarderSeeded(address indexed forwarder);
    event ForwarderPruned(address indexed forwarder, address indexed solver);

    error OwnershipCannotBeRenounced();
    error TooManySolvers();
    error ZeroAddress();

    constructor(address owner_, address[] memory solvers_) Ownable(owner_) {
        for (uint256 i = 0; i < solvers_.length; i++) {
            _setSolver(solvers_[i], true);
        }
    }

    /// @notice Adds a solver to the list, or takes one off it.
    /// @dev Changes no forwarder by itself: {seed} and {prune} apply the list to each one.
    function setSolver(address solver, bool listed) external onlyOwner {
        _setSolver(solver, listed);
    }

    /// @inheritdoc IVedaForwarderSteward
    /// @dev Open to anyone. Reverts when it would have to change a forwarder this contract does not
    ///      own; a forwarder that already has every listed solver approved is left alone. The event
    ///      says only that the call was made, for whatever address was named.
    function seed(address forwarder) external returns (uint256 approved) {
        VedaForwardingSolver target = VedaForwardingSolver(forwarder);
        approved = _solvers.length;
        for (uint256 i = 0; i < approved; i++) {
            if (!target.isAuthorizedSolver(_solvers[i])) target.setAuthorizedSolver(_solvers[i], true);
        }
        emit ForwarderSeeded(forwarder);
    }

    /// @notice Removes from `forwarder` every named account that is approved there and not on the list.
    /// @dev Open to anyone. An account on the list is left alone, so this cannot stop a forwarder.
    function prune(address forwarder, address[] calldata accounts) external {
        VedaForwardingSolver target = VedaForwardingSolver(forwarder);
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (isSolver[account] || !target.isAuthorizedSolver(account)) continue;
            target.setAuthorizedSolver(account, false);
            emit ForwarderPruned(forwarder, account);
        }
    }

    /// @notice Sets where `forwarder` sends rescued surplus.
    function setForwarderTreasury(VedaForwardingSolver forwarder, address newTreasury) external onlyOwner {
        forwarder.setTreasury(newTreasury);
    }

    /// @notice Sends `amount` of `token` held by `forwarder` to that forwarder's treasury.
    function rescue(VedaForwardingSolver forwarder, address token, uint256 amount) external onlyOwner {
        forwarder.rescue(token, amount);
    }

    /// @notice Offers `forwarder` to another owner, who must accept it. Until then this contract still
    ///         owns it; afterwards the list here no longer reaches it.
    function releaseForwarder(VedaForwardingSolver forwarder, address newOwner) external onlyOwner {
        forwarder.transferOwnership(newOwner);
    }

    /// @notice Takes over a forwarder whose owner offered it to this contract, so the list reaches it.
    function acceptForwarder(VedaForwardingSolver forwarder) external onlyOwner {
        forwarder.acceptOwnership();
    }

    /// @notice Disabled: without an owner the list could never change, and every forwarder this
    ///         contract owns would lose its treasury, rescue and release functions for good.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice The solvers every forwarder should approve.
    function solvers() external view returns (address[] memory) {
        return _solvers;
    }

    function _setSolver(address solver, bool listed) private {
        if (solver == address(0)) revert ZeroAddress();
        if (isSolver[solver] == listed) return;
        isSolver[solver] = listed;
        if (listed) {
            if (_solvers.length == MAX_SOLVERS) revert TooManySolvers();
            _solvers.push(solver);
        } else {
            uint256 last = _solvers.length - 1;
            for (uint256 i = 0; i <= last; i++) {
                if (_solvers[i] != solver) continue;
                _solvers[i] = _solvers[last];
                _solvers.pop();
                break;
            }
        }
        emit SolverChanged(solver, listed);
    }
}
