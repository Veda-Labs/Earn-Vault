// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IVedaVaultRegistry } from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IBoringQueue } from "../../../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../interfaces/external/veda/IBoringSolver.sol";
import { IForwardingEngine, VedaForwardingSolver } from "../VedaForwardingSolver.sol";
import { VedaLockstepEngine } from "./VedaLockstepEngine.sol";

/// @title VedaLockstepEngineDeployer
/// @notice Holds {VedaLockstepEngine}'s creation code so a {VedaStackFactory} can build engines without
///         embedding it, which would put the factory over the contract size limit.
/// @dev Stateless and open to anyone: an engine holds no permission until the vault's administration
///      authorizes it, and a factory authorizes only an engine this contract returned to it in the same
///      call. One deployer serves every factory on a chain.
contract VedaLockstepEngineDeployer {
    event VedaLockstepEngineDeployed(address indexed engine, address indexed vaultRegistry, address indexed owner);

    function deploy(
        IVedaVaultRegistry vaultRegistry,
        address owner,
        uint64 maxRateAge,
        string calldata name,
        string calldata symbol
    ) external returns (address engine) {
        engine = address(new VedaLockstepEngine(vaultRegistry, owner, maxRateAge, name, symbol));
        emit VedaLockstepEngineDeployed(engine, address(vaultRegistry), owner);
    }
}

/// @title VedaForwardingSolverDeployer
/// @notice Holds {VedaForwardingSolver}'s creation code for a {VedaStackFactory}, for the same reason.
/// @dev Stateless and open to anyone: a forwarding solver settles nothing until its engine's owner
///      authorizes it and the vault's administration lets it call the stock solver.
contract VedaForwardingSolverDeployer {
    event VedaForwardingSolverDeployed(address indexed forwarder, address indexed engine, address indexed owner);

    function deploy(
        IBoringSolver boringSolver,
        IBoringQueue queue,
        address teller,
        address engine,
        address owner,
        address treasury
    ) external returns (address forwarder) {
        forwarder = address(
            new VedaForwardingSolver(boringSolver, queue, teller, IForwardingEngine(engine), owner, treasury)
        );
        emit VedaForwardingSolverDeployed(forwarder, engine, owner);
    }
}
