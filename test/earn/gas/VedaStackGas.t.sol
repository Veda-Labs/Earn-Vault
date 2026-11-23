// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Gas of building a stack through VedaStackFactory, in one call and in two, on a vault whose Teller
// gates its callers and on one whose Teller keeps an account allowlist. Run under the Tempo hardfork
// to read it against Tempo's per-transaction gas cap:
//   FOUNDRY_PROFILE=spend forge test --match-path test/earn/gas/VedaStackGas.t.sol --no-match-path none -vv
// forge-lint: disable-start(multi-contract-file)
import { console2 } from "forge-std/Test.sol";
import { VedaForwarderSteward } from "../../../src/earn/engines/veda/shared/VedaForwarderSteward.sol";
import { AuthedQueue, AuthedSolver, AuthedTeller } from "../helpers/VedaAuthMocks.sol";
import { VedaAllowlistStackTestBase, VedaRoleStackTestBase, VedaStackTestBase } from "../helpers/VedaStackTestBase.sol";

abstract contract VedaStackGasAudit is VedaStackTestBase {
    bytes32 internal constant STACK = keccak256("gas-stack");

    function testGasCreateStackWithQueue() public {
        vm.pauseGasMetering();
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK), address(0));
        _stopMeasure("factory.createStack.queued", gasBefore);
        assertEq(factory.engineCount(), 1);
    }

    function testGasCreateStackImmediateOnly() public {
        vm.pauseGasMetering();
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK), address(0));
        _stopMeasure("factory.createStack.immediate", gasBefore);
        assertEq(factory.engineCount(), 1);
    }

    function testGasDeployEngine() public {
        vm.pauseGasMetering();
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.deployEngine(_nextJob(), _engineParams());
        _stopMeasure("factory.deployEngine", gasBefore);
        assertEq(factory.engineCount(), 1);
    }

    function testGasFinalizeStackWithQueue() public {
        vm.pauseGasMetering();
        vm.prank(operator);
        address engine = factory.deployEngine(_nextJob(), _engineParams());
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.finalizeStack(engine, _coreParams(STACK), address(0));
        _stopMeasure("factory.finalizeStack.queued", gasBefore);
        assertTrue(factory.stack(engine).forwarder != address(0));
    }

    function testGasDeployForwarder() public {
        vm.pauseGasMetering();
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        vm.prank(operator);
        (address engine,,) = factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK), address(0));
        _rotate(teller, queue, solver);
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        address forwarder = factory.deployForwarder(engine);
        _stopMeasure("factory.deployForwarder", gasBefore);
        assertTrue(forwarder != address(0));
    }

    function _startMeasure() internal returns (uint256 gasBefore) {
        vm.resumeGasMetering();
        gasBefore = gasleft();
    }

    function _stopMeasure(string memory label, uint256 gasBefore) internal {
        uint256 rawGas = gasBefore - gasleft();
        vm.pauseGasMetering();
        console2.log(label, rawGas);
    }
}

contract VedaRoleStackGasAudit is VedaRoleStackTestBase, VedaStackGasAudit {
    function setUp() public override(VedaStackTestBase) {
        super.setUp();
    }
}

/// @dev The role granter with its allowlist flag set, so that it also lists the engine, and a steward
///      that approves one solver on each forwarding solver: everything a build can write.
contract VedaAllowlistStackGasAudit is VedaAllowlistStackTestBase, VedaStackGasAudit {
    function setUp() public override(VedaStackTestBase) {
        address[] memory solvers = new address[](1);
        solvers[0] = solverBot;
        forwarderOwner = address(new VedaForwarderSteward(makeAddr("solver safe"), solvers));
        forwarderOwnerIsSteward = true;
        super.setUp();
    }

    function _newTeller() internal override(VedaStackTestBase, VedaAllowlistStackTestBase) returns (AuthedTeller) {
        return super._newTeller();
    }

    function _newQueue(address accountant_)
        internal
        override(VedaStackTestBase, VedaAllowlistStackTestBase)
        returns (AuthedQueue)
    {
        return super._newQueue(accountant_);
    }

    function _configureVeda() internal override(VedaStackTestBase, VedaAllowlistStackTestBase) {
        super._configureVeda();
    }

    function _adminSetupForTeller() internal override(VedaStackTestBase, VedaAllowlistStackTestBase) {
        super._adminSetupForTeller();
    }

    function _admitModules(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_)
        internal
        override(VedaStackTestBase, VedaAllowlistStackTestBase)
    {
        super._admitModules(teller_, queue_, solver_);
    }
}
// forge-lint: disable-end(multi-contract-file)
