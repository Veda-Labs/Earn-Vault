// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// A vault's Queue is a backup that may go unused for a long time, so a forwarding solver has to be able
// to settle from the day it is built. These tests pin down that a factory whose forwarders a steward
// owns builds them with the vault's solver already approved, that the steward's list reaches every
// forwarder without a transaction from its owner, and that readiness can be read before it is needed.
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { IForwardingEngine, VedaForwardingSolver } from "../../../../../src/earn/engines/veda/VedaForwardingSolver.sol";
import { VedaForwarderSteward } from "../../../../../src/earn/engines/veda/shared/VedaForwarderSteward.sol";
import { VedaEngine } from "../../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaStackFactory } from "../../../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { AuthedQueue, AuthedSolver } from "../../../helpers/VedaAuthMocks.sol";
import { StackMockShareToken } from "../../../helpers/VedaStackMocks.sol";
import { VedaRoleStackTestBase } from "../../../helpers/VedaStackTestBase.sol";

contract VedaForwarderStewardTest is VedaRoleStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");
    bytes32 internal constant STACK_B = keccak256("stack-b");

    /// @dev The Safe that owns the steward.
    address internal safe = makeAddr("solver safe");
    address internal secondBot = makeAddr("second solver bot");
    VedaForwarderSteward internal steward;

    function setUp() public override {
        address[] memory solvers = new address[](1);
        solvers[0] = solverBot;
        steward = new VedaForwarderSteward(safe, solvers);
        forwarderOwner = address(steward);
        forwarderOwnerIsSteward = true;
        super.setUp();
    }

    // ------------------------------------------------------------------
    // Built ready
    // ------------------------------------------------------------------

    function testAForwarderIsBuiltWithTheVaultsSolverApprovedAndSettlesWithNoOwnerTransaction() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);

        assertEq(forwarder.owner(), address(steward));
        assertTrue(forwarder.isAuthorizedSolver(solverBot));
        assertTrue(factory.isForwarderReady(address(forwarder), solverBot));
        assertFalse(factory.isForwarderReady(address(forwarder), stranger));

        _deposit(earnVault, user, 100e6);
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 25e6);
        assertEq(_trigger(forwarder, solverBot, requestId), 1);
        assertEq(asset.balanceOf(user), 25e6);
    }

    function testAForwarderBuiltLaterIsSeededToo() public {
        // A stack built before the vault had a Queue gets its forwarder afterwards.
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        assertEq(factory.stack(address(engine)).forwarder, address(0));
        _rotate(teller, queue, solver);

        vm.prank(operator);
        address forwarder = factory.deployForwarder(address(engine));
        assertTrue(VedaForwardingSolver(forwarder).isAuthorizedSolver(solverBot));
        // Its engine's owner has neither admitted it nor moved the engine to the Queue, and readiness
        // says so until both are done.
        assertFalse(factory.isForwarderReady(forwarder, solverBot));
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(forwarder, true);
        assertFalse(factory.isForwarderReady(forwarder, solverBot));
        _activate(engine, earnVault);
        assertTrue(factory.isForwarderReady(forwarder, solverBot));
    }

    function testAFactoryCannotNameAKeyAsItsStewardOrTheStewardAsTreasury() public {
        VedaStackFactory.Config memory config = _factoryConfig();
        config.forwarderOwner = stranger;
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, stranger));
        new VedaStackFactory(config);
        assertTrue(factory.forwarderOwnerIsSteward());

        // The steward cannot move tokens, so surplus rescued to it would be stranded.
        config = _factoryConfig();
        config.forwarderTreasury = address(steward);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, address(steward)));
        new VedaStackFactory(config);
    }

    function testAForwarderNoListedSolverCouldTriggerIsNotBuilt() public {
        vm.prank(safe);
        steward.setSolver(solverBot, false);

        // On a vault with a Queue, a stack whose backup could not settle is not reported as built.
        vm.prank(operator);
        vm.expectPartialRevert(VedaStackFactory.ForwarderNotSeeded.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);

        vm.prank(safe);
        steward.setSolver(solverBot, true);
        _createStack(STACK_A);
        assertEq(factory.engineCount(), 1);
    }

    function testTheStewardCannotBeLeftWithoutAnOwnerAndCanTakeOverAForwarder() public {
        vm.prank(safe);
        vm.expectRevert(VedaForwarderSteward.OwnershipCannotBeRenounced.selector);
        steward.renounceOwnership();
        assertEq(steward.owner(), safe);

        // A forwarder built under another owner is brought under the list once that owner offers it.
        VedaForwardingSolver foreign = new VedaForwardingSolver(
            IBoringSolver(address(solver)),
            IBoringQueue(address(queue)),
            address(teller),
            IForwardingEngine(makeAddr("some engine")),
            stranger,
            treasury
        );
        vm.prank(stranger);
        foreign.transferOwnership(address(steward));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        steward.acceptForwarder(foreign);
        vm.prank(safe);
        steward.acceptForwarder(foreign);
        assertEq(foreign.owner(), address(steward));
        assertEq(steward.seed(address(foreign)), 1);
        assertTrue(foreign.isAuthorizedSolver(solverBot));
    }

    // ------------------------------------------------------------------
    // One list for every forwarder
    // ------------------------------------------------------------------

    function testTheListReachesEveryForwarderWithoutItsOwner() public {
        (VedaEngine engineA, EarnVault vaultA, StackMockShareToken shareA) = _createStack(STACK_A);
        (VedaEngine engineB,,) = _createStack(STACK_B);
        VedaForwardingSolver forwarderA = VedaForwardingSolver(factory.stack(address(engineA)).forwarder);
        VedaForwardingSolver forwarderB = VedaForwardingSolver(factory.stack(address(engineB)).forwarder);

        // The Safe changes the list once; anyone applies it to each forwarder.
        vm.prank(safe);
        steward.setSolver(secondBot, true);
        assertFalse(forwarderA.isAuthorizedSolver(secondBot));
        vm.startPrank(stranger);
        steward.seed(address(forwarderA));
        steward.seed(address(forwarderB));
        vm.stopPrank();
        assertTrue(forwarderA.isAuthorizedSolver(secondBot));
        assertTrue(forwarderB.isAuthorizedSolver(secondBot));
        assertTrue(forwarderA.isAuthorizedSolver(solverBot));

        // A retired solver stays approved on a forwarder until someone prunes it there. Nothing on the
        // list can be pruned, so nobody can stop a forwarder this way.
        vm.prank(safe);
        steward.setSolver(solverBot, false);
        assertTrue(forwarderA.isAuthorizedSolver(solverBot));
        address[] memory accounts = new address[](3);
        accounts[0] = solverBot;
        accounts[1] = secondBot;
        accounts[2] = stranger;
        vm.prank(stranger);
        steward.prune(address(forwarderA), accounts);
        assertFalse(forwarderA.isAuthorizedSolver(solverBot));
        assertTrue(forwarderA.isAuthorizedSolver(secondBot));
        assertFalse(factory.isForwarderReady(address(forwarderA), solverBot));
        assertTrue(factory.isForwarderReady(address(forwarderA), secondBot));

        // The retired solver can no longer trigger; the new one settles.
        _deposit(vaultA, user, 100e6);
        bytes32 requestId = _requestRedeem(vaultA, shareA, user, 10e6);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = requestId;
        vm.prank(solverBot);
        vm.expectRevert(abi.encodeWithSelector(VedaForwardingSolver.NotAuthorizedSolver.selector, solverBot));
        forwarderA.solveAndForward(ids, false);
        assertEq(_trigger(forwarderA, secondBot, requestId), 1);

        // A stack built after the change gets the list as it is now.
        (VedaEngine engineC,,) = _createStack(keccak256("stack-c"));
        VedaForwardingSolver forwarderC = VedaForwardingSolver(factory.stack(address(engineC)).forwarder);
        assertTrue(forwarderC.isAuthorizedSolver(secondBot));
        assertFalse(forwarderC.isAuthorizedSolver(solverBot));
    }

    function testOnlyItsOwnerEditsTheListWhichIsBounded() public {
        address[4] memory others = [stranger, operator, admin, address(factory)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, others[i]));
            steward.setSolver(secondBot, true);
        }

        vm.startPrank(safe);
        vm.expectRevert(VedaForwarderSteward.ZeroAddress.selector);
        steward.setSolver(address(0), true);
        // Setting what is already set changes nothing.
        steward.setSolver(solverBot, true);
        steward.setSolver(secondBot, false);
        assertEq(steward.solvers().length, 1);

        uint256 max = steward.MAX_SOLVERS();
        for (uint256 i = 1; i < max; i++) {
            steward.setSolver(address(uint160(0x5000 + i)), true);
        }
        assertEq(steward.solvers().length, max);
        vm.expectRevert(VedaForwarderSteward.TooManySolvers.selector);
        steward.setSolver(secondBot, true);

        // Removing one from the middle keeps the rest.
        steward.setSolver(address(uint160(0x5003)), false);
        assertEq(steward.solvers().length, max - 1);
        assertFalse(steward.isSolver(address(uint160(0x5003))));
        assertTrue(steward.isSolver(solverBot));
        assertTrue(steward.isSolver(address(uint160(0x5000 + max - 1))));
        steward.setSolver(secondBot, true);
        vm.stopPrank();
        assertEq(steward.solvers().length, max);
    }

    function testTheStewardChangesOnlyForwardersItOwns() public {
        VedaForwardingSolver foreign = new VedaForwardingSolver(
            IBoringSolver(address(solver)),
            IBoringQueue(address(queue)),
            address(teller),
            IForwardingEngine(makeAddr("some engine")),
            stranger,
            treasury
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(steward)));
        steward.seed(address(foreign));
        assertFalse(foreign.isAuthorizedSolver(solverBot));
    }

    function testItsOwnerKeepsTheForwardersOtherOwnerFunctions() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);
        address newTreasury = makeAddr("new treasury");
        address newOwner = makeAddr("new forwarder owner");

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        steward.setForwarderTreasury(forwarder, newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        steward.rescue(forwarder, address(asset), 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        steward.releaseForwarder(forwarder, stranger);
        vm.stopPrank();

        // Surplus left on a forwarder goes to its treasury, and only there.
        asset.mint(address(forwarder), 7e6);
        vm.startPrank(safe);
        steward.setForwarderTreasury(forwarder, newTreasury);
        steward.rescue(forwarder, address(asset), 7e6);
        assertEq(asset.balanceOf(newTreasury), 7e6);

        // Handing a forwarder on takes the new owner's acceptance; until then the list still reaches it.
        steward.releaseForwarder(forwarder, newOwner);
        vm.stopPrank();
        assertEq(forwarder.owner(), address(steward));
        assertEq(forwarder.pendingOwner(), newOwner);
        vm.prank(newOwner);
        forwarder.acceptOwnership();
        assertEq(forwarder.owner(), newOwner);
        // The list no longer reaches it: a later change cannot be applied there.
        vm.prank(safe);
        steward.setSolver(secondBot, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(steward)));
        steward.seed(address(forwarder));
        assertFalse(forwarder.isAuthorizedSolver(secondBot));
    }

    // ------------------------------------------------------------------
    // Knowing the backup works before it is needed
    // ------------------------------------------------------------------

    function testReadinessFollowsEverythingAQueuedExitNeeds() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        address forwarder = factory.stack(address(engine)).forwarder;
        assertTrue(factory.isForwarderReady(forwarder, solverBot));
        assertFalse(factory.isForwarderReady(stranger, solverBot));

        // The engine's owner stops admitting it.
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(forwarder, false);
        assertFalse(factory.isForwarderReady(forwarder, solverBot));
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(forwarder, true);
        assertTrue(factory.isForwarderReady(forwarder, solverBot));

        // A pauser revokes it, and the administrator reinstates it.
        vm.prank(pauser);
        factory.revokeForwarder(forwarder);
        assertFalse(factory.isForwarderReady(forwarder, solverBot));
        vm.prank(admin);
        factory.reinstateForwarder(forwarder);
        assertTrue(factory.isForwarderReady(forwarder, solverBot));

        // Its permission on the stock solver is taken away behind the factory's back.
        vm.prank(admin);
        rolesAuthority.setUserRole(forwarder, EARN_FORWARDER_ROLE, false);
        assertFalse(factory.isForwarderReady(forwarder, solverBot));
        vm.prank(admin);
        rolesAuthority.setUserRole(forwarder, EARN_FORWARDER_ROLE, true);
        assertTrue(factory.isForwarderReady(forwarder, solverBot));

        // The vault publishes another Queue. The engine keeps the old one until its owner activates
        // the publication, so its forwarder is still the one that settles.
        (AuthedQueue newQueue, AuthedSolver newSolver) = _newExitRail(address(accountant));
        _rotate(teller, newQueue, newSolver);
        assertTrue(factory.isForwarderReady(forwarder, solverBot));
        vm.prank(operator);
        address replacement = factory.deployForwarder(address(engine));
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(replacement, true);
        assertFalse(factory.isForwarderReady(replacement, solverBot));

        // Once the owner activates it, the replacement is what a new request needs.
        _activate(engine, earnVault);
        assertTrue(factory.isForwarderReady(replacement, solverBot));
        assertFalse(factory.isForwarderReady(forwarder, solverBot));

        // An engine moved to an immediate-only tuple has no queued path to be ready.
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        assertTrue(factory.isForwarderReady(replacement, solverBot));
        _activate(engine, earnVault);
        assertFalse(factory.isForwarderReady(replacement, solverBot));
    }

    function _trigger(VedaForwardingSolver forwarder, address bot, bytes32 requestId)
        private
        returns (uint256 forwarded)
    {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = requestId;
        vm.prank(bot);
        forwarded = forwarder.solveAndForward(ids, false);
    }
}
