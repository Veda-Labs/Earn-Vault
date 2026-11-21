// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Gas of building a stack through VedaStackFactory, in one call and in two, with each authorization
// variant. Run under the Tempo hardfork to read it against Tempo's per-transaction gas cap:
//   FOUNDRY_PROFILE=spend forge test --match-path test/earn/gas/VedaStackGas.t.sol --no-match-path none -vv
// forge-lint: disable-start(multi-contract-file)
import { console2 } from "forge-std/Test.sol";
import { AuthedQueue, AuthedSolver } from "../helpers/VedaAuthMocks.sol";
import { VedaOverlayStackTestBase, VedaRoleStackTestBase, VedaStackTestBase } from "../helpers/VedaStackTestBase.sol";

abstract contract VedaStackGasAudit is VedaStackTestBase {
    bytes32 internal constant STACK = keccak256("gas-stack");

    function testGasCreateStackWithQueue() public {
        vm.pauseGasMetering();
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.createStack(_engineParams(), _coreParams(STACK), address(0));
        _stopMeasure("factory.createStack.queued", gasBefore);
        assertEq(factory.engineCount(), 1);
    }

    function testGasCreateStackImmediateOnly() public {
        vm.pauseGasMetering();
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.createStack(_engineParams(), _coreParams(STACK), address(0));
        _stopMeasure("factory.createStack.immediate", gasBefore);
        assertEq(factory.engineCount(), 1);
    }

    function testGasDeployEngine() public {
        vm.pauseGasMetering();
        vm.prank(operator);
        uint256 gasBefore = _startMeasure();
        factory.deployEngine(_engineParams());
        _stopMeasure("factory.deployEngine", gasBefore);
        assertEq(factory.engineCount(), 1);
    }

    function testGasFinalizeStackWithQueue() public {
        vm.pauseGasMetering();
        vm.prank(operator);
        address engine = factory.deployEngine(_engineParams());
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
        (address engine,,) = factory.createStack(_engineParams(), _coreParams(STACK), address(0));
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

contract VedaOverlayStackGasAudit is VedaOverlayStackTestBase, VedaStackGasAudit {
    function setUp() public override(VedaStackTestBase) {
        super.setUp();
    }
}
// forge-lint: disable-end(multi-contract-file)
