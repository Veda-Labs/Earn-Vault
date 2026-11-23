// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IBoringQueue } from "../../../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../interfaces/external/veda/IBoringSolver.sol";
import { IVedaPeripheryRegistry } from "../../../../interfaces/external/veda/IVedaPeripheryRegistry.sol";
import { VedaEngine } from "../VedaEngine.sol";
import { IForwardingEngine, VedaForwardingSolver } from "../VedaForwardingSolver.sol";

/// @title VedaEngineDeployer
/// @notice Holds {VedaEngine}'s creation code so a {VedaStackFactory} can build engines without
///         embedding it, which would put the factory over the contract size limit.
/// @dev Stateless and open to anyone: an engine holds no permission until the vault's administration
///      authorizes it, and a factory authorizes only an engine this contract returned to it in the same
///      call. One deployer serves every factory on a chain.
contract VedaEngineDeployer {
    event VedaEngineDeployed(address indexed engine, address indexed peripheryRegistry, address indexed owner);

    function deploy(
        IVedaPeripheryRegistry peripheryRegistry,
        address owner,
        uint64 maxRateAge,
        string calldata name,
        string calldata symbol
    ) external returns (address engine) {
        engine = address(new VedaEngine(peripheryRegistry, owner, maxRateAge, name, symbol));
        emit VedaEngineDeployed(engine, address(peripheryRegistry), owner);
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
