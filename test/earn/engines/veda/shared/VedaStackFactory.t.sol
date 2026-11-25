// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// The stack factory, exercised over a finalized Veda vault whose modules gate their callers, the
// canonical Earn core and the released `VedaEngine`. `VedaRoleGranterAdmission.t.sol` covers a vault
// whose Teller also admits by account.
// forge-lint: disable-start(multi-contract-file)
import { EarnFactory } from "../../../../../src/earn/core/EarnFactory.sol";
import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { EngineMigrationMode } from "../../../../../src/interfaces/earn/EarnVaultTypes.sol";
import { IEarnVault } from "../../../../../src/interfaces/earn/IEarnVault.sol";
import { IEarnEngine } from "../../../../../src/interfaces/earn/engines/IEarnEngine.sol";
import { IForwardingEngine, VedaForwardingSolver } from "../../../../../src/earn/engines/veda/VedaForwardingSolver.sol";
import { VedaEngine } from "../../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaRoleGranter } from "../../../../../src/earn/engines/veda/shared/VedaRoleGranter.sol";
import {
    VedaForwardingSolverDeployer,
    VedaEngineDeployer
} from "../../../../../src/earn/engines/veda/shared/VedaStackDeployers.sol";
import { VedaStackFactory } from "../../../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IEarnEngineAsyncRedeem } from "../../../../../src/interfaces/earn/engines/IEarnEngineAsyncRedeem.sol";
import {
    IVedaStackAuthorizer,
    IVedaVaultRegistry
} from "../../../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { TIP403_REGISTRY_ADDRESS } from "../../../../../src/interfaces/external/tempo/ITIP403Registry.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { IBoringVaultCustody, IRolesAuthority } from "../../../../../src/interfaces/external/veda/IRolesAuthority.sol";
import { IAccountant } from "../../../../../src/interfaces/external/veda/IAccountant.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../../../../src/interfaces/external/veda/IVedaPeripheryRegistry.sol";
import {
    AuthedBoringVault,
    AuthedQueue,
    AuthedSolver,
    AuthedTeller,
    MockRolesAuthority
} from "../../../helpers/VedaAuthMocks.sol";
import { MockAccountant, MockBoringVault } from "../../../helpers/VedaEngineMocks.sol";
import { StackMockShareToken, StackMockTip403Registry } from "../../../helpers/VedaStackMocks.sol";
import { VedaRoleStackTestBase, VedaStackTestBase } from "../../../helpers/VedaStackTestBase.sol";

/// @dev An engine deployer that returns whatever it is told to, standing for a factory pinned to the
///      wrong deployer.
contract HostileEngineDeployer {
    address public next;

    function setNext(address next_) external {
        next = next_;
    }

    function deploy(IVedaPeripheryRegistry, address, uint64, string calldata, string calldata)
        external
        view
        returns (address)
    {
        return next;
    }
}

/// @dev A forwarder deployer that builds a genuine forwarding solver with one thing changed, standing for
///      a factory pinned to the wrong deployer.
contract HostileForwarderDeployer {
    enum Twist {
        Engine,
        Owner,
        Treasury,
        Queue,
        Solver,
        Teller,
        NotAContract
    }

    Twist public twist;
    address public substitute;
    IBoringQueue public substituteQueue;

    function set(Twist twist_, address substitute_, IBoringQueue substituteQueue_) external {
        twist = twist_;
        substitute = substitute_;
        substituteQueue = substituteQueue_;
    }

    function deploy(
        IBoringSolver boringSolver,
        IBoringQueue queue,
        address teller,
        address engine,
        address owner,
        address treasury
    ) external returns (address) {
        Twist t = twist;
        if (t == Twist.NotAContract) return substitute;
        return address(
            new VedaForwardingSolver(
                t == Twist.Solver ? IBoringSolver(substitute) : boringSolver,
                t == Twist.Queue ? substituteQueue : queue,
                t == Twist.Teller ? substitute : teller,
                IForwardingEngine(t == Twist.Engine ? substitute : engine),
                t == Twist.Owner ? substitute : owner,
                t == Twist.Treasury ? substitute : treasury
            )
        );
    }
}

/// @dev An operator that is also the factory's engine deployer, and re-enters the factory from it.
contract ReentrantOperator {
    VedaStackFactory public factory;

    function setFactory(VedaStackFactory factory_) external {
        factory = factory_;
    }

    function run() external {
        factory.deployEngine(
            keccak256("outer"), VedaStackFactory.EngineParams({ name: "V", symbol: "v", maxRateAge: 1 days })
        );
    }

    function deploy(IVedaPeripheryRegistry, address, uint64, string calldata, string calldata)
        external
        returns (address)
    {
        factory.deployEngine(
            keccak256("inner"), VedaStackFactory.EngineParams({ name: "V", symbol: "v", maxRateAge: 1 days })
        );
        return address(0);
    }
}

abstract contract VedaStackFactoryBehavior is VedaStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");
    bytes32 internal constant STACK_B = keccak256("stack-b");

    event StackCreated(
        address indexed engine,
        address indexed earnVault,
        address indexed earnShare,
        address earnFees,
        address forwarder,
        address owner,
        address creator
    );
    event TransferPolicyCreated(uint64 indexed policyId, address indexed admin);
    event ClosedToNewStacksChanged(bool closed, address indexed by);
    event RequiredStackOwnerChanged(address indexed oldOwner, address indexed newOwner, address indexed by);

    // ------------------------------------------------------------------
    // Building a stack
    // ------------------------------------------------------------------

    function testCreateStackBuildsBindsAuthorizesAndRecordsInOneOperatorCall() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        VedaStackFactory.StackRecord memory record = factory.stack(address(engine));

        // The canonical core, bound both ways, and handed to the stack's owner in the same call.
        assertEq(earnVault.engine(), address(engine));
        assertEq(engine.earnVault(), address(earnVault));
        assertEq(earnVault.earnShare(), address(earnShare));
        assertEq(earnVault.operator(), stackOwner);
        assertEq(engine.owner(), stackOwner);
        assertEq(engine.pendingOwner(), address(0));
        // The released engine, on the vault's registry and the tuple published when it was built.
        assertEq(address(engine.peripheryRegistry()), address(registry));
        assertEq(address(engine.teller()), address(teller));
        assertEq(address(engine.queue()), address(queue));
        assertEq(address(engine.accountant()), address(accountant));
        assertEq(engine.peripheryVersion(), registry.version());
        assertEq(earnShare.name(), "Veda Vault (Earn)");
        assertEq(earnShare.symbol(), "vVAULTE");

        assertEq(uint256(record.status), uint256(VedaStackFactory.EngineStatus.Active));
        assertEq(record.earnVault, address(earnVault));
        assertEq(record.earnShare, address(earnShare));
        assertEq(record.earnFees, earnVault.earnFees());
        assertEq(record.creator, operator);
        assertEq(record.createdAtBlock, block.number);
        assertEq(factory.engineCount(), 1);
        assertEq(factory.engineAt(0), address(engine));

        // The vault has a Queue, so the stack carries a forwarding solver Veda owns.
        VedaForwardingSolver forwarder = VedaForwardingSolver(record.forwarder);
        assertTrue(address(forwarder) != address(0));
        assertTrue(engine.authorizedForwarder(address(forwarder)));
        assertEq(forwarder.owner(), forwarderOwner);
        assertEq(forwarder.treasury(), treasury);
        assertEq(address(forwarder.engine()), address(engine));
        assertEq(address(forwarder.queue()), address(queue));
        assertEq(address(forwarder.boringSolver()), address(solver));
        assertEq(forwarder.teller(), address(teller));
        VedaStackFactory.ForwarderRecord memory forwarderRecord = factory.forwarderRecord(address(forwarder));
        assertEq(forwarderRecord.engine, address(engine));
        assertEq(uint256(forwarderRecord.status), uint256(VedaStackFactory.ForwarderStatus.Active));

        // Exactly the calls a stack needs, as the modules themselves would decide them.
        assertTrue(_canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
        assertTrue(_canCall(address(engine), address(teller), ITeller.bulkWithdraw.selector));
        assertTrue(_canCall(address(engine), address(queue), IBoringQueue.requestOnChainWithdraw.selector));
        assertTrue(_canCall(address(engine), address(queue), IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector));
        assertTrue(_canCall(address(forwarder), address(solver), IBoringSolver.boringRedeemSolve.selector));
        assertFalse(_canCall(address(engine), address(solver), IBoringSolver.boringRedeemSolve.selector));
        assertFalse(_canCall(address(forwarder), address(teller), ITeller.bulkWithdraw.selector));
        assertFalse(_canCall(address(engine), address(queue), AuthedQueue.solveOnChainWithdraws.selector));
    }

    function testCreateStackEmitsTheRecord() public {
        vm.expectEmit(false, false, false, false, address(factory));
        emit StackCreated(address(0), address(0), address(0), address(0), address(0), address(0), address(0));
        _createStack(STACK_A);
    }

    function testStackServesDepositsInstantExitsAndQueuedExitsEndToEnd() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);

        assertEq(_deposit(earnVault, user, 100e6), 100e6);
        assertEq(vault.balanceOf(address(engine)), 100e6);
        assertEq(asset.balanceOf(address(vault)), 100e6);

        // Instant exit through the Teller's bulk path.
        vm.startPrank(user);
        earnShare.approve(address(earnVault), 40e6);
        assertEq(earnVault.redeem(40e6, receiver, 40e6), 40e6);
        vm.stopPrank();
        assertEq(asset.balanceOf(receiver), 40e6);

        // Queued exit, settled by the stack's forwarding solver through the stock solver.
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 25e6);
        assertEq(vault.balanceOf(address(queue)), 25e6);
        assertEq(engine.unresolvedClaimCount(), 1);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);
        assertEq(_solve(forwarder, requestId), 1);

        assertEq(asset.balanceOf(user), 25e6);
        assertEq(engine.unresolvedClaimCount(), 0);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(earnVault.openRedeemRequestCount(), 0);
        assertEq(vault.balanceOf(address(engine)), 35e6);
    }

    function testQueuedExitCanBeCancelled() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 25e6);

        vm.prank(user);
        earnVault.cancelRedeem(requestId, 1);

        assertEq(vault.balanceOf(address(engine)), 100e6);
        assertEq(earnShare.balanceOf(user), 100e6);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testTwoTransactionBuildEndsInTheSameStack() public {
        vm.prank(operator);
        address engine = factory.deployEngine(_nextJob(), _engineParams());

        // Between the two halves: owned by the factory, bound to nothing, authorized for nothing.
        VedaStackFactory.StackRecord memory pending = factory.stack(engine);
        assertEq(uint256(pending.status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertEq(VedaEngine(engine).owner(), address(factory));
        assertEq(VedaEngine(engine).earnVault(), address(0));
        assertFalse(_canCall(engine, address(teller), ITeller.bulkDeposit.selector));
        assertFalse(_canCall(engine, address(teller), ITeller.bulkWithdraw.selector));
        assertFalse(_canCall(engine, address(queue), IBoringQueue.requestOnChainWithdraw.selector));

        vm.prank(operator);
        (address earnVault, address earnShare) = factory.finalizeStack(engine, _coreParams(STACK_A), address(0));

        VedaStackFactory.StackRecord memory record = factory.stack(engine);
        assertEq(uint256(record.status), uint256(VedaStackFactory.EngineStatus.Active));
        assertEq(record.earnVault, earnVault);
        assertEq(record.earnShare, earnShare);
        assertEq(VedaEngine(engine).owner(), stackOwner);
        assertEq(VedaEngine(engine).earnVault(), earnVault);
        assertEq(factory.engineCount(), 1);
        assertEq(_deposit(EarnVault(earnVault), user, 10e6), 10e6);
    }

    function testSharedFactoryCanCreateAnOperatorMigratableStack() public {
        EarnFactory.DeployParams memory params = _coreParams(STACK_A);
        params.controls.migrationMode = EngineMigrationMode.UserOnly;
        vm.prank(operator);
        (, address userOnlyVault,) = factory.createStack(_nextJob(), _engineParams(), params, address(0));
        assertEq(uint256(EarnVault(userOnlyVault).engineMigrationMode()), uint256(EngineMigrationMode.UserOnly));

        params = _coreParams(STACK_B);
        params.owner = admin;
        params.controls.migrationMode = EngineMigrationMode.OperatorEnabled;
        vm.prank(operator);
        (address engine, address earnVault,) = factory.createStack(_nextJob(), _engineParams(), params, address(0));

        assertEq(uint256(EarnVault(earnVault).engineMigrationMode()), uint256(EngineMigrationMode.OperatorEnabled));
        assertEq(EarnVault(earnVault).operator(), admin);
        assertEq(VedaEngine(engine).owner(), admin);
    }

    function testEarnVaultOperatorPreparesMigrationEngineAndMovesFundedPool() public {
        (VedaEngine oldEngine, EarnVault earnVault, StackMockShareToken earnShare) = _migratableStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        bytes32 jobId = _nextJob();
        vm.prank(operator);
        address replacement = factory.deployMigrationEngine(jobId, _engineParams(), address(earnVault));

        assertEq(factory.migrationTargetOf(replacement), address(earnVault));
        assertEq(factory.engineOf(jobId), replacement);
        assertEq(uint256(factory.stack(replacement).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertEq(VedaEngine(replacement).owner(), address(factory));
        assertEq(VedaEngine(replacement).earnVault(), address(0));
        assertFalse(_canCall(replacement, address(teller), ITeller.bulkDeposit.selector));

        vm.prank(stackOwner);
        address forwarder = factory.finalizeMigrationEngine(replacement);
        VedaStackFactory.StackRecord memory record = factory.stack(replacement);
        assertEq(uint256(record.status), uint256(VedaStackFactory.EngineStatus.Active));
        assertEq(record.earnVault, address(earnVault));
        assertEq(record.earnShare, address(0));
        assertEq(record.earnFees, address(0));
        assertEq(record.forwarder, forwarder);
        assertEq(record.creator, operator);
        assertEq(record.createdAtBlock, block.number);
        assertEq(VedaEngine(replacement).earnVault(), address(earnVault));
        assertEq(VedaEngine(replacement).owner(), stackOwner);
        assertEq(earnVault.engine(), address(oldEngine));
        assertTrue(factory.isEngineReady(replacement));
        assertTrue(VedaEngine(replacement).authorizedForwarder(forwarder));
        assertTrue(_canCall(forwarder, address(solver), IBoringSolver.boringRedeemSolve.selector));

        vm.prank(stackOwner);
        earnVault.migrateEngine(replacement, 100e6, 100e6);
        assertEq(earnVault.engine(), replacement);
        assertEq(oldEngine.totalShares(), 0);
        assertEq(VedaEngine(replacement).totalShares(), 100e6);
        assertEq(earnVault.totalAssets(), 100e6);
        assertEq(earnShare.balanceOf(user), 100e6);
    }

    function testMigrationMovesFundedPoolBetweenDistinctBoringVaults() public {
        (VedaEngine oldEngine, EarnVault earnVault, StackMockShareToken earnShare) = _migratableStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        (VedaStackFactory destinationFactory, AuthedBoringVault destinationVault, AuthedTeller destinationTeller) =
            _newImmediateDestination();
        assertTrue(address(destinationVault) != address(vault));

        vm.prank(operator);
        address replacement = destinationFactory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        assertEq(destinationFactory.migrationTargetOf(replacement), address(earnVault));
        assertEq(address(VedaEngine(replacement).vault()), address(destinationVault));
        assertFalse(_canCall(replacement, address(destinationTeller), ITeller.bulkDeposit.selector));

        vm.prank(stackOwner);
        address forwarder = destinationFactory.finalizeMigrationEngine(replacement);
        assertEq(forwarder, address(0));
        assertTrue(_canCall(replacement, address(destinationTeller), ITeller.bulkDeposit.selector));
        assertEq(vault.balanceOf(address(oldEngine)), 100e6);
        assertEq(destinationVault.balanceOf(replacement), 0);

        vm.prank(stackOwner);
        earnVault.migrateEngine(replacement, 100e6, 100e6);
        assertEq(earnVault.engine(), replacement);
        assertEq(vault.balanceOf(address(oldEngine)), 0);
        assertEq(destinationVault.balanceOf(replacement), 100e6);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(destinationVault)), 100e6);
        assertEq(earnVault.totalAssets(), 100e6);
        assertEq(earnShare.balanceOf(user), 100e6);
    }

    function testMigrationCandidateRequiresCommittedTargetAndCannotBecomeFreshStack() public {
        (, EarnVault earnVault,) = _migratableStack(STACK_A);
        vm.prank(operator);
        address ordinary = factory.deployEngine(_nextJob(), _engineParams());
        vm.prank(stackOwner);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.MigrationTargetMissing.selector, ordinary));
        factory.finalizeMigrationEngine(ordinary);

        vm.prank(operator);
        address reserved = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(VedaStackFactory.MigrationTargetReserved.selector, reserved, address(earnVault))
        );
        factory.finalizeStack(reserved, _coreParams(STACK_B), address(0));
        assertEq(uint256(factory.stack(reserved).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertFalse(_canCall(reserved, address(teller), ITeller.bulkDeposit.selector));
    }

    function testMigrationCandidateUsesLiveEarnVaultOperatorAndCannotBeFinalizedTwice() public {
        (, EarnVault earnVault,) = _migratableStack(STACK_A);
        vm.prank(operator);
        address replacement = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotEarnVaultOperator.selector, stranger, stackOwner));
        factory.finalizeMigrationEngine(replacement);
        vm.prank(stackOwner);
        earnVault.transferOperator(admin);
        vm.prank(admin);
        earnVault.acceptOperator();
        vm.prank(stackOwner);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotEarnVaultOperator.selector, stackOwner, admin));
        factory.finalizeMigrationEngine(replacement);
        vm.prank(admin);
        factory.finalizeMigrationEngine(replacement);
        assertEq(VedaEngine(replacement).owner(), admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, replacement));
        factory.finalizeMigrationEngine(replacement);
    }

    function testMigrationCandidateRejectsDisabledModeAssetMismatchAndUnboundSource() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidMigrationTarget.selector, stranger));
        factory.deployMigrationEngine(_nextJob(), _engineParams(), stranger);

        EarnFactory.DeployParams memory disabledParams = _coreParams(STACK_A);
        disabledParams.controls.migrationMode = EngineMigrationMode.UserOnly;
        vm.prank(operator);
        (, address disabledAddress,) = factory.createStack(_nextJob(), _engineParams(), disabledParams, address(0));
        EarnVault disabled = EarnVault(disabledAddress);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.MigrationDisabled.selector, address(disabled)));
        factory.deployMigrationEngine(_nextJob(), _engineParams(), address(disabled));

        (VedaEngine oldEngine, EarnVault earnVault,) = _migratableStack(STACK_B);
        vm.mockCall(address(earnVault), abi.encodeWithSelector(IEarnVault.asset.selector), abi.encode(stranger));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.MigrationAssetMismatch.selector, address(earnVault), address(asset), stranger
            )
        );
        factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.clearMockedCalls();

        vm.mockCall(address(oldEngine), abi.encodeWithSelector(IEarnEngine.earnVault.selector), abi.encode(stranger));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.InvalidMigrationSource.selector, address(earnVault), address(oldEngine)
            )
        );
        factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
    }

    function testMigrationCandidateRechecksSourceAndJobBeforeGrantingRoles() public {
        (VedaEngine oldEngine, EarnVault earnVault,) = _migratableStack(STACK_A);
        bytes32 jobId = _nextJob();
        vm.prank(operator);
        address replacement = factory.deployMigrationEngine(jobId, _engineParams(), address(earnVault));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.JobAlreadyBuilt.selector, jobId, replacement));
        factory.deployMigrationEngine(jobId, _engineParams(), address(earnVault));

        vm.mockCall(address(oldEngine), abi.encodeWithSelector(IEarnEngine.earnVault.selector), abi.encode(stranger));
        vm.prank(stackOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.InvalidMigrationSource.selector, address(earnVault), address(oldEngine)
            )
        );
        factory.finalizeMigrationEngine(replacement);
        vm.clearMockedCalls();
        assertEq(uint256(factory.stack(replacement).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertFalse(_canCall(replacement, address(teller), ITeller.bulkDeposit.selector));
    }

    function testMigrationCandidateStalePausedDiscardedAndFailedGrantRemainInert() public {
        (, EarnVault earnVault,) = _migratableStack(STACK_A);
        vm.prank(operator);
        address stale = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        AuthedTeller newTeller = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        _rotate(newTeller, queue, solver);
        vm.prank(stackOwner);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EnginePeripheryStale.selector, stale, 1, 2));
        factory.finalizeMigrationEngine(stale);
        vm.prank(pauser);
        factory.discardEngine(stale);
        vm.prank(stackOwner);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, stale));
        factory.finalizeMigrationEngine(stale);

        vm.prank(operator);
        address fresh = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.prank(pauser);
        factory.pauseRegistrations();
        vm.prank(stackOwner);
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.finalizeMigrationEngine(fresh);
        vm.prank(admin);
        factory.resumeRegistrations();

        _dropForwarderAccess();
        vm.prank(stackOwner);
        vm.expectPartialRevert(VedaStackFactory.NotAuthorizedOnVeda.selector);
        factory.finalizeMigrationEngine(fresh);
        assertEq(uint256(factory.stack(fresh).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertEq(VedaEngine(fresh).earnVault(), address(0));
        assertFalse(_canCall(fresh, address(newTeller), ITeller.bulkDeposit.selector));
    }

    function _migratableStack(bytes32 deploymentId)
        internal
        returns (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare)
    {
        EarnFactory.DeployParams memory params = _coreParams(deploymentId);
        params.controls.migrationMode = EngineMigrationMode.OperatorEnabled;
        vm.prank(operator);
        (address engine_, address earnVault_, address earnShare_) =
            factory.createStack(_nextJob(), _engineParams(), params, address(0));
        return (VedaEngine(engine_), EarnVault(earnVault_), StackMockShareToken(earnShare_));
    }

    function _newImmediateDestination()
        internal
        returns (
            VedaStackFactory destinationFactory,
            AuthedBoringVault destinationVault,
            AuthedTeller destinationTeller
        )
    {
        MockRolesAuthority destinationRoles = new MockRolesAuthority(admin, address(0));
        destinationVault = new AuthedBoringVault(address(0), address(destinationRoles), 6);
        MockAccountant destinationAccountant =
            new MockAccountant(MockBoringVault(address(destinationVault)), address(asset));
        destinationTeller =
            new AuthedTeller(address(0), address(destinationRoles), destinationVault, address(destinationAccountant));
        VedaVaultRegistry destinationRegistry =
            new VedaVaultRegistry(IBoringVault(address(destinationVault)), address(asset));
        vm.startPrank(admin);
        destinationRoles.setRoleCapability(
            MINTER_ROLE, address(destinationVault), IBoringVaultCustody.enter.selector, true
        );
        destinationRoles.setRoleCapability(
            BURNER_ROLE, address(destinationVault), IBoringVaultCustody.exit.selector, true
        );
        destinationRoles.setUserRole(address(destinationTeller), MINTER_ROLE, true);
        destinationRoles.setUserRole(address(destinationTeller), BURNER_ROLE, true);
        destinationRegistry.publish(
            ITeller(address(destinationTeller)),
            IBoringQueue(address(0)),
            IAccountant(address(destinationAccountant)),
            IBoringSolver(address(0))
        );

        VedaRoleGranter destinationGranter = new VedaRoleGranter(
            IRolesAuthority(address(destinationRoles)),
            IVedaVaultRegistry(address(destinationRegistry)),
            EARN_ENGINE_ROLE,
            EARN_FORWARDER_ROLE
        );
        VedaStackFactory.Config memory config = _factoryConfig();
        config.registry = IVedaVaultRegistry(address(destinationRegistry));
        config.authorizer = IVedaStackAuthorizer(address(destinationGranter));
        destinationFactory = new VedaStackFactory(config);
        destinationRoles.setRoleCapability(
            EARN_ENGINE_ROLE, address(destinationTeller), ITeller.bulkDeposit.selector, true
        );
        destinationRoles.setRoleCapability(
            EARN_ENGINE_ROLE, address(destinationTeller), ITeller.bulkWithdraw.selector, true
        );
        destinationRoles.setAuthority(address(destinationGranter));
        destinationGranter.setFactory(address(destinationFactory), true);
        destinationGranter.assertSetup(IVedaVaultRegistry(address(destinationRegistry)), address(destinationFactory));
        vm.stopPrank();
    }

    function testFinalizeAcceptsOnlyAnEngineThisFactoryDeployedAndOnlyOnce() public {
        // Anyone can use the public deployer, even naming the factory as owner. The factory still
        // refuses the result: it authorizes only engines it deployed in its own call.
        address foreign = engineDeployer.deploy(
            IVedaPeripheryRegistry(address(registry)), address(factory), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, foreign));
        factory.finalizeStack(foreign, _coreParams(STACK_A), address(0));

        (VedaEngine engine,,) = _createStack(STACK_A);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, address(engine)));
        factory.finalizeStack(address(engine), _coreParams(STACK_B), address(0));

        assertFalse(_canCall(foreign, address(teller), ITeller.bulkDeposit.selector));
        assertEq(uint256(factory.stack(foreign).status), uint256(VedaStackFactory.EngineStatus.None));
    }

    function testRevertedFinalizeLeavesTheEnginePendingUnboundAndUnauthorized() public {
        vm.prank(operator);
        address engine = factory.deployEngine(_nextJob(), _engineParams());

        EarnFactory.DeployParams memory bad = _coreParams(bytes32(0));
        vm.prank(operator);
        vm.expectRevert(EarnFactory.EmptyDeploymentId.selector);
        factory.finalizeStack(engine, bad, address(0));

        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertEq(VedaEngine(engine).owner(), address(factory));
        assertEq(VedaEngine(engine).earnVault(), address(0));
        assertFalse(_canCall(engine, address(teller), ITeller.bulkDeposit.selector));

        vm.prank(operator);
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0));
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Active));
    }

    function testCoreParametersCannotNameAnEngineOrLeaveTheFactoryAsOwner() public {
        EarnFactory.DeployParams memory params = _coreParams(STACK_A);
        params.engine = makeAddr("some engine");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineMustBeUnset.selector, params.engine));
        factory.createStack(_nextJob(), _engineParams(), params, address(0));

        params = _coreParams(STACK_A);
        params.owner = address(factory);
        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.FactoryCannotBeOwner.selector);
        factory.createStack(_nextJob(), _engineParams(), params, address(0));

        params = _coreParams(STACK_A);
        params.owner = address(0);
        vm.prank(operator);
        vm.expectRevert(EarnFactory.ZeroAddress.selector);
        factory.createStack(_nextJob(), _engineParams(), params, address(0));
        assertEq(factory.engineCount(), 0);
    }

    function testOnlyTheOperatorBuilds() public {
        vm.prank(operator);
        address pendingEngine = factory.deployEngine(_nextJob(), _engineParams());
        (VedaEngine engine,,) = _createStack(STACK_A);

        address[4] memory callers = [stranger, admin, pauser, stackOwner];
        for (uint256 i = 0; i < callers.length; i++) {
            bytes memory notOperator = abi.encodeWithSelector(VedaStackFactory.NotOperator.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(notOperator);
            factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_B), address(0));
            vm.expectRevert(notOperator);
            factory.deployEngine(_nextJob(), _engineParams());
            vm.expectRevert(notOperator);
            factory.finalizeStack(pendingEngine, _coreParams(STACK_B), address(0));
            vm.expectRevert(notOperator);
            factory.deployForwarder(address(engine));
            vm.stopPrank();
        }
    }

    function testStacksOnOneVaultAreSeparateAndEachOwnerActivatesAPublication() public {
        (VedaEngine engineA, EarnVault vaultA,) = _createStack(STACK_A);
        (VedaEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        assertTrue(address(engineA) != address(engineB));
        _deposit(vaultA, user, 10e6);
        _deposit(vaultB, user, 20e6);
        assertEq(vault.balanceOf(address(engineA)), 10e6);
        assertEq(vault.balanceOf(address(engineB)), 20e6);

        // One publication by the administrator moves neither stack: each keeps working on the Teller
        // it was built on, which the administrator leaves live.
        AuthedTeller newTeller = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        _rotate(newTeller, queue, solver);
        _deposit(vaultA, user, 1e6);
        _deposit(vaultB, user, 1e6);
        assertEq(newTeller.bulkDepositCalls(), 0);
        assertTrue(factory.isEngineReady(address(engineA)));

        // One owner activates it, as for any `VedaEngine`; the other stack is untouched.
        _activate(engineA, vaultA);
        _deposit(vaultA, user, 1e6);
        _deposit(vaultB, user, 1e6);
        assertEq(newTeller.bulkDepositCalls(), 1);
        assertEq(address(engineA.teller()), address(newTeller));
        assertEq(address(engineB.teller()), address(teller));
        assertEq(engineA.peripheryVersion(), registry.version());
        assertTrue(factory.isEngineReady(address(engineA)));
        assertTrue(factory.isEngineReady(address(engineB)));

        // A stack built now starts on the published tuple.
        (VedaEngine engineC,,) = _createStack(keccak256("stack-c"));
        assertEq(address(engineC.teller()), address(newTeller));
    }

    function testAnEngineLeftPendingAcrossAPublicationIsNeverBound() public {
        vm.prank(operator);
        address stale = factory.deployEngine(_nextJob(), _engineParams());
        AuthedTeller newTeller = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        _rotate(newTeller, queue, solver);

        // The engine fixed the earlier Teller when it was deployed, and only its final owner could
        // move it, so the factory does not hand over a stack that starts on replaced modules.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EnginePeripheryStale.selector, stale, 1, 2));
        factory.finalizeStack(stale, _coreParams(STACK_A), address(0));
        assertEq(uint256(factory.stack(stale).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertEq(VedaEngine(stale).earnVault(), address(0));
        assertFalse(rolesAuthority.doesUserHaveRole(stale, EARN_ENGINE_ROLE));

        // A new engine under a new job id takes its place.
        vm.startPrank(operator);
        address fresh = factory.deployEngine(_nextJob(), _engineParams());
        factory.finalizeStack(fresh, _coreParams(STACK_A), address(0));
        vm.stopPrank();
        assertEq(address(VedaEngine(fresh).teller()), address(newTeller));
        assertTrue(factory.isEngineReady(fresh));
    }

    function testAJobIdBuildsOneEngineHoweverOftenItIsSent() public {
        bytes32 job = keccak256("job-one");
        vm.prank(operator);
        (address engine,,) = factory.createStack(job, _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineOf(job), engine);

        // The same build sent again, or the same job with other settings, builds nothing.
        bytes memory alreadyBuilt = abi.encodeWithSelector(VedaStackFactory.JobAlreadyBuilt.selector, job, engine);
        vm.startPrank(operator);
        vm.expectRevert(alreadyBuilt);
        factory.createStack(job, _engineParams(), _coreParams(STACK_A), address(0));
        vm.expectRevert(alreadyBuilt);
        factory.createStack(job, _engineParams(), _coreParams(STACK_B), address(0));
        vm.expectRevert(alreadyBuilt);
        factory.deployEngine(job, _engineParams());
        vm.expectRevert(VedaStackFactory.EmptyJobId.selector);
        factory.createStack(bytes32(0), _engineParams(), _coreParams(STACK_B), address(0));
        vm.expectRevert(VedaStackFactory.EmptyJobId.selector);
        factory.deployEngine(bytes32(0), _engineParams());
        vm.stopPrank();
        assertEq(factory.engineCount(), 1);

        // In two transactions the first half is the one a job id guards; the second already accepts
        // an engine once.
        bytes32 second = keccak256("job-two");
        vm.startPrank(operator);
        address pending = factory.deployEngine(second, _engineParams());
        assertEq(factory.engineOf(second), pending);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.JobAlreadyBuilt.selector, second, pending));
        factory.deployEngine(second, _engineParams());
        factory.finalizeStack(pending, _coreParams(STACK_B), address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, pending));
        factory.finalizeStack(pending, _coreParams(STACK_B), address(0));
        vm.stopPrank();
        assertEq(factory.engineCount(), 2);
    }

    function testPausersDiscardAPendingEngineSoItCanNeverBeFinalized() public {
        bytes32 job = keccak256("job-one");
        vm.prank(operator);
        address pending = factory.deployEngine(job, _engineParams());
        (VedaEngine active,,) = _createStack(STACK_A);

        address[3] memory nonPausers = [stranger, operator, stackOwner];
        for (uint256 i = 0; i < nonPausers.length; i++) {
            vm.prank(nonPausers[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotPauser.selector, nonPausers[i]));
            factory.discardEngine(pending);
        }
        // Only an engine that was never bound can be discarded.
        vm.startPrank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, address(active)));
        factory.discardEngine(address(active));
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, stranger));
        factory.discardEngine(stranger);
        factory.discardEngine(pending);
        vm.stopPrank();
        assertEq(uint256(factory.stack(pending).status), uint256(VedaStackFactory.EngineStatus.Discarded));

        // Nothing brings it back: not a finalize, not a reinstatement, not its job id.
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, pending));
        factory.finalizeStack(pending, _coreParams(STACK_B), address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.JobAlreadyBuilt.selector, job, pending));
        factory.deployEngine(job, _engineParams());
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotRevoked.selector, pending));
        factory.reinstateEngine(pending);
        assertFalse(_canCall(pending, address(teller), ITeller.bulkDeposit.selector));
        assertEq(VedaEngine(pending).earnVault(), address(0));
    }

    function testAJobWhoseBuildRevertedCanBeSentAgain() public {
        bytes32 job = keccak256("job-one");
        vm.prank(operator);
        vm.expectRevert(EarnFactory.EmptyDeploymentId.selector);
        factory.createStack(job, _engineParams(), _coreParams(bytes32(0)), address(0));
        assertEq(factory.engineOf(job), address(0));

        vm.prank(operator);
        (address engine,,) = factory.createStack(job, _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineOf(job), engine);
    }

    // ------------------------------------------------------------------
    // Fail closed
    // ------------------------------------------------------------------

    function testAStackIsNeverReportedBuiltWhenItsPermissionsAreNotInPlace() public {
        // A Teller the administrator published without admitting the Earn stacks to it.
        AuthedTeller unadmitted = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        vm.startPrank(admin);
        _grantTellerVaultRoles(unadmitted);
        vm.stopPrank();
        _publishUnadmittedTeller(unadmitted);

        vm.prank(operator);
        vm.expectPartialRevert(VedaStackFactory.NotAuthorizedOnVeda.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);
    }

    function testAFactoryBuildsNothingUntilTheAdministratorNamesIt() public {
        VedaStackFactory unnamed = new VedaStackFactory(_factoryConfig());
        assertFalse(unnamed.isAuthorizerBound());
        assertTrue(factory.isAuthorizerBound());

        vm.startPrank(operator);
        vm.expectRevert(VedaStackFactory.AuthorizerNotBound.selector);
        unnamed.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        // Not even a pending engine.
        vm.expectRevert(VedaStackFactory.AuthorizerNotBound.selector);
        unnamed.deployEngine(_nextJob(), _engineParams());
        vm.stopPrank();
        assertEq(unnamed.engineCount(), 0);
    }

    function testAFactoryOnAnotherRegistryOfTheSameVaultCannotBeNamed() public {
        // An engine takes its modules from its registry, so a factory building on a registry the
        // administrator never published on must not receive the vault's authorizations.
        VedaStackFactory.Config memory config = _factoryConfig();
        config.registry = IVedaVaultRegistry(address(_newLookalikeRegistry()));
        VedaStackFactory misdirected = new VedaStackFactory(config);

        vm.prank(admin);
        vm.expectPartialRevert(_notWiredSelector());
        _nameFactory(misdirected);
        assertFalse(misdirected.isAuthorizerBound());
    }

    function testASecondFactoryBuildsNewStacksWhileTheFirstStillServesItsOwn() public {
        (VedaEngine first, EarnVault firstVault,) = _createStack(STACK_A);
        VedaStackFactory second = new VedaStackFactory(_factoryConfig());
        vm.startPrank(admin);
        _nameFactory(second);
        rolesAuthority.setRoleCapability(PAUSER_ROLE, address(second), VedaStackFactory.revokeEngine.selector, true);
        vm.stopPrank();

        vm.prank(operator);
        (address secondEngine, address secondVault,) =
            second.createStack(_nextJob(), _engineParams(), _coreParams(STACK_B), address(0));
        assertEq(_deposit(EarnVault(secondVault), user, 5e6), 5e6);
        assertEq(_deposit(firstVault, user, 5e6), 5e6);

        // Each factory reaches only the stacks it built.
        vm.startPrank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, address(first)));
        second.revokeEngine(address(first));
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, secondEngine));
        factory.revokeEngine(secondEngine);
        // The first factory's pausers keep their lever over its stacks, and its operator its forwarders.
        factory.revokeEngine(address(first));
        vm.stopPrank();
        assertFalse(_canCall(address(first), address(teller), ITeller.bulkDeposit.selector));
        assertTrue(_canCall(secondEngine, address(teller), ITeller.bulkDeposit.selector));
        vm.prank(admin);
        factory.reinstateEngine(address(first));
        vm.prank(operator);
        assertTrue(factory.deployForwarder(address(first)) != address(0));

        // Once the administrator stops naming the first factory, it builds and changes nothing more.
        vm.prank(admin);
        _unnameFactory(factory);
        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.AuthorizerNotBound.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(keccak256("stack-c")), address(0));
        vm.prank(pauser);
        vm.expectRevert();
        factory.revokeEngine(address(first));
        // Its stacks keep working.
        assertEq(_deposit(firstVault, user, 1e6), 1e6);
    }

    function testFactoryRejectsAnEngineItsDeployerDidNotBuildForIt() public {
        HostileEngineDeployer hostile = new HostileEngineDeployer();
        VedaStackFactory.Config memory config = _factoryConfig();
        config.engineDeployer = VedaEngineDeployer(address(hostile));
        config.engineDeployerCodeHash = address(hostile).codehash;
        VedaStackFactory hostileFactory = _newBoundFactory(config);

        // Not a contract, owned by someone else, already bound, or already one of its own stacks.
        address[4] memory candidates;
        candidates[0] = makeAddr("not a contract");
        candidates[1] = address(
            new VedaEngine(IVedaPeripheryRegistry(address(registry)), stranger, MAX_RATE_AGE, "Veda Vault", "v")
        );
        VedaEngine bound =
            new VedaEngine(IVedaPeripheryRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "v");
        bound.initializeEarnVault(makeAddr("some vault"));
        bound.transferOwnership(address(hostileFactory));
        candidates[2] = address(bound);
        (VedaEngine live,,) = _createStack(STACK_A);
        candidates[3] = address(live);

        for (uint256 i = 0; i < candidates.length; i++) {
            hostile.setNext(candidates[i]);
            vm.prank(operator);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidEngineDeployment.selector, candidates[i]));
            hostileFactory.deployEngine(_nextJob(), _engineParams());
        }
        assertEq(hostileFactory.engineCount(), 0);
    }

    function testFactoryRejectsAForwarderItsDeployerDidNotBuildForIt() public {
        // A stack is never built around a forwarding solver for another engine, owner, treasury, Queue,
        // stock solver or Teller, so the forwarder role only ever lands on the solver the record names.
        HostileForwarderDeployer hostile = new HostileForwarderDeployer();
        VedaStackFactory.Config memory config = _factoryConfig();
        config.forwarderDeployer = VedaForwardingSolverDeployer(address(hostile));
        config.forwarderDeployerCodeHash = address(hostile).codehash;
        VedaStackFactory hostileFactory = _newBoundFactory(config);
        (AuthedQueue otherQueue,) = _newExitRail(address(accountant));

        for (uint256 i = 0; i <= uint256(HostileForwarderDeployer.Twist.NotAContract); i++) {
            hostile.set(HostileForwarderDeployer.Twist(i), stranger, IBoringQueue(address(otherQueue)));
            vm.prank(operator);
            vm.expectPartialRevert(VedaStackFactory.InvalidForwarderDeployment.selector);
            hostileFactory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        }
        assertEq(hostileFactory.engineCount(), 0);
    }

    function testAReinstatedForwarderMustStillBeAllowedOnItsStockSolver() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        address forwarder = factory.stack(address(engine)).forwarder;
        vm.prank(pauser);
        factory.revokeForwarder(forwarder);

        // The administrator has since stopped honoring that stock solver for the Earn stacks.
        _dropForwarderAccess();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.NotAuthorizedOnVeda.selector,
                forwarder,
                address(solver),
                IBoringSolver.boringRedeemSolve.selector
            )
        );
        factory.reinstateForwarder(forwarder);
        assertEq(uint256(factory.forwarderRecord(forwarder).status), uint256(VedaStackFactory.ForwarderStatus.Revoked));
    }

    function testTheFactoryCannotBeNamedAdministratorOfANewTransferPolicy() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidTransferPolicyAdmin.selector, address(factory)));
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(factory));
        assertEq(factory.engineCount(), 0);
    }

    function testBuildingCannotBeReentered() public {
        ReentrantOperator reentrant = new ReentrantOperator();
        VedaStackFactory.Config memory config = _factoryConfig();
        config.engineDeployer = VedaEngineDeployer(address(reentrant));
        config.engineDeployerCodeHash = address(reentrant).codehash;
        config.operator = address(reentrant);
        VedaStackFactory guarded = _newBoundFactory(config);
        reentrant.setFactory(guarded);

        vm.expectRevert(VedaStackFactory.ReentrantCall.selector);
        reentrant.run();
        assertEq(guarded.engineCount(), 0);
    }

    function testConstructorPinsItsWiringAndRejectsBadWiring() public {
        assertEq(address(factory.registry()), address(registry));
        assertEq(address(factory.authorizer()), address(granter));
        assertEq(address(factory.earnFactory()), address(earnFactory));
        assertEq(factory.earnFactoryCodeHash(), address(earnFactory).codehash);
        assertEq(factory.engineDeployerCodeHash(), address(engineDeployer).codehash);
        assertEq(factory.forwarderDeployerCodeHash(), address(forwarderDeployer).codehash);
        assertEq(factory.forwarderOwner(), forwarderOwner);
        assertEq(factory.forwarderTreasury(), treasury);
        assertEq(factory.operator(), operator);

        // Each pinned contract is named by the code hash of its reviewed release.
        VedaStackFactory.Config memory config = _factoryConfig();
        bytes32 anotherRelease = keccak256("another release");
        config.earnFactoryCodeHash = anotherRelease;
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.CodeHashMismatch.selector,
                address(earnFactory),
                anotherRelease,
                address(earnFactory).codehash
            )
        );
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.engineDeployerCodeHash = anotherRelease;
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.CodeHashMismatch.selector,
                address(engineDeployer),
                anotherRelease,
                address(engineDeployer).codehash
            )
        );
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.forwarderDeployerCodeHash = anotherRelease;
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaStackFactory.CodeHashMismatch.selector,
                address(forwarderDeployer),
                anotherRelease,
                address(forwarderDeployer).codehash
            )
        );
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.operator = address(0);
        vm.expectRevert(VedaStackFactory.ZeroAddress.selector);
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.forwarderOwner = address(0);
        vm.expectRevert(VedaStackFactory.ZeroAddress.selector);
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.forwarderTreasury = address(0);
        vm.expectRevert(VedaStackFactory.ZeroAddress.selector);
        new VedaStackFactory(config);

        address codeless = makeAddr("codeless");
        config = _factoryConfig();
        config.registry = IVedaVaultRegistry(codeless);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, codeless));
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.authorizer = IVedaStackAuthorizer(codeless);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, codeless));
        new VedaStackFactory(config);

        // A factory always has a granter: nothing else admits its stacks.
        config = _factoryConfig();
        config.authorizer = IVedaStackAuthorizer(address(0));
        vm.expectRevert(VedaStackFactory.ZeroAddress.selector);
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.engineDeployer = VedaEngineDeployer(codeless);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, codeless));
        new VedaStackFactory(config);

        config = _factoryConfig();
        config.forwarderDeployer = VedaForwardingSolverDeployer(codeless);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, codeless));
        new VedaStackFactory(config);
    }

    // ------------------------------------------------------------------
    // Custody stays out of reach
    // ------------------------------------------------------------------

    function testNothingTheFactoryBuildsOrUsesCanReachVaultCustody() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        address forwarder = factory.stack(address(engine)).forwarder;
        address[5] memory accounts = [address(factory), address(granter), address(engine), forwarder, operator];
        bytes4[] memory custody = _custodySelectors();

        // The BoringVault still answers to the RolesAuthority and to nothing else.
        assertEq(vault.authority(), address(rolesAuthority));
        assertEq(vault.owner(), address(0));
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < custody.length; j++) {
                assertFalse(_canCall(accounts[i], address(vault), custody[j]));
            }
        }

        vm.prank(address(engine));
        vm.expectRevert(bytes("UNAUTHORIZED"));
        vault.manage(address(asset), abi.encodeCall(asset.transfer, (address(engine), 1)), 0);
        vm.prank(address(factory));
        vm.expectRevert(bytes("UNAUTHORIZED"));
        vault.exit(address(factory), address(asset), 1, address(engine), 0);
        vm.prank(forwarder);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        vault.enter(forwarder, address(asset), 0, forwarder, 1e6);
    }

    function testEnginesAlreadyLiveOnTheVaultKeepWorkingUntouched() public {
        _createStack(STACK_A);
        assertTrue(_canCall(legacyEngine, address(teller), ITeller.bulkDeposit.selector));
        assertTrue(_canCall(legacyEngine, address(teller), ITeller.bulkWithdraw.selector));
        assertTrue(_canCall(legacyEngine, address(queue), IBoringQueue.requestOnChainWithdraw.selector));

        asset.mint(legacyEngine, 5e6);
        vm.startPrank(legacyEngine);
        asset.approve(address(vault), 5e6);
        teller.bulkDeposit(address(asset), 5e6, 0, legacyEngine);
        teller.bulkWithdraw(address(asset), 2e6, 0, legacyEngine);
        vm.stopPrank();
        assertEq(vault.balanceOf(legacyEngine), 3e6);
    }

    // ------------------------------------------------------------------
    // Immediate-only vaults and later forwarders
    // ------------------------------------------------------------------

    function testImmediateOnlyVaultGetsAStackWithoutAForwarderAndGainsQueuedExitsLater() public {
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        assertEq(factory.stack(address(engine)).forwarder, address(0));
        assertFalse(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));
        _deposit(earnVault, user, 50e6);

        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.QueueUnavailable.selector);
        factory.deployForwarder(address(engine));

        // The administrator publishes a Queue. The stack gains queued exits once the operator builds
        // it a forwarder and its owner admits that and activates the publication.
        _rotate(teller, queue, solver);
        assertFalse(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));

        vm.prank(operator);
        address forwarder = factory.deployForwarder(address(engine));
        // The stack's own record is untouched; the new forwarder has its own.
        assertEq(factory.stack(address(engine)).forwarder, address(0));
        assertEq(factory.forwarderRecord(forwarder).engine, address(engine));
        assertEq(uint256(factory.forwarderRecord(forwarder).status), uint256(VedaStackFactory.ForwarderStatus.Active));
        assertTrue(_canCall(forwarder, address(solver), IBoringSolver.boringRedeemSolve.selector));
        // The factory no longer owns the engine, so the engine's owner admits the forwarder.
        assertFalse(engine.authorizedForwarder(forwarder));
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(forwarder, true);
        _activate(engine, earnVault);
        assertTrue(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));

        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 20e6);
        assertEq(_solve(VedaForwardingSolver(forwarder), requestId), 1);
        assertEq(asset.balanceOf(user), 20e6);
    }

    function testAForwarderIsBuiltOnlyForAnActiveEngineOfThisFactory() public {
        vm.prank(operator);
        address pendingEngine = factory.deployEngine(_nextJob(), _engineParams());
        address[2] memory engines = [pendingEngine, makeAddr("unknown engine")];
        for (uint256 i = 0; i < engines.length; i++) {
            vm.prank(operator);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, engines[i]));
            factory.deployForwarder(engines[i]);
        }
    }

    function testAQueueChangeKeepsOldRequestsSettlingAndNeedsANewForwarder() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        bytes32 oldRequest = _requestRedeem(earnVault, earnShare, user, 10e6);
        VedaForwardingSolver oldForwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);

        (AuthedQueue newQueue, AuthedSolver newSolver) = _newExitRail(address(accountant));
        _rotate(teller, newQueue, newSolver);
        assertEq(address(engine.queue()), address(queue));

        // The new Queue needs its own forwarder, which the owner admits as it activates the Queue.
        vm.prank(operator);
        address newForwarder = factory.deployForwarder(address(engine));
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(newForwarder, true);
        _activate(engine, earnVault);
        assertEq(address(engine.queue()), address(newQueue));
        assertEq(engine.claimQueue(oldRequest), address(queue));
        skip(1);
        bytes32 newRequest = _requestRedeem(earnVault, earnShare, user, 15e6);
        assertEq(engine.claimQueue(newRequest), address(newQueue));

        // The old request settles through its own Queue, stock solver and forwarder.
        assertEq(_solve(oldForwarder, oldRequest), 1);
        assertEq(_solve(VedaForwardingSolver(newForwarder), newRequest), 1);
        assertEq(asset.balanceOf(user), 25e6);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    // ------------------------------------------------------------------
    // Pausers reduce, the administrator restores
    // ------------------------------------------------------------------

    function testPausersRevokeAnEngineAndOnlyTheAdministratorReinstatesIt() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 10e6);

        address[3] memory nonPausers = [stranger, operator, stackOwner];
        for (uint256 i = 0; i < nonPausers.length; i++) {
            vm.prank(nonPausers[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotPauser.selector, nonPausers[i]));
            factory.revokeEngine(address(engine));
        }

        assertTrue(factory.canEngineUseTeller(address(engine)));
        assertFalse(factory.canEngineUseTeller(stranger));
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        assertFalse(factory.canEngineUseTeller(address(engine)));
        assertFalse(_canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
        assertFalse(_canCall(address(engine), address(teller), ITeller.bulkWithdraw.selector));
        assertFalse(_canCall(address(engine), address(queue), IBoringQueue.requestOnChainWithdraw.selector));

        // Deposits and instant exits stop for this stack...
        asset.mint(user, 1e6);
        vm.startPrank(user);
        asset.approve(address(earnVault), 1e6);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        earnVault.deposit(1e6, user, 1);
        earnShare.approve(address(earnVault), 1e6);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        earnVault.redeem(1e6, receiver, 1);
        vm.stopPrank();
        // ...while a request already queued still settles.
        assertEq(_solve(VedaForwardingSolver(factory.stack(address(engine)).forwarder), requestId), 1);
        assertEq(asset.balanceOf(user), 11e6);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, address(engine)));
        factory.revokeEngine(address(engine));

        // Restoring is the administrator's alone.
        address[3] memory nonAdmins = [pauser, operator, stackOwner];
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, nonAdmins[i]));
            factory.reinstateEngine(address(engine));
        }
        vm.prank(admin);
        factory.reinstateEngine(address(engine));
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Active));
        vm.prank(user);
        assertEq(earnVault.deposit(1e6, user, 1), 1e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotRevoked.selector, address(engine)));
        factory.reinstateEngine(address(engine));
    }

    function testAnotherStackIsUntouchedByARevocation() public {
        (VedaEngine engineA,,) = _createStack(STACK_A);
        (VedaEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));

        assertEq(uint256(factory.stack(address(engineB)).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertEq(_deposit(vaultB, user, 5e6), 5e6);
    }

    function testPausersRevokeAForwarderAndOnlyTheAdministratorReinstatesIt() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 10e6);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotPauser.selector, stranger));
        factory.revokeForwarder(address(forwarder));
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.ForwarderNotActive.selector, stranger));
        factory.revokeForwarder(stranger);

        vm.prank(pauser);
        factory.revokeForwarder(address(forwarder));
        assertFalse(_canCall(address(forwarder), address(solver), IBoringSolver.boringRedeemSolve.selector));
        vm.prank(forwarderOwner);
        forwarder.setAuthorizedSolver(solverBot, true);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = requestId;
        vm.prank(solverBot);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        forwarder.solveAndForward(ids, false);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, pauser));
        factory.reinstateForwarder(address(forwarder));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.ForwarderNotRevoked.selector, stranger));
        factory.reinstateForwarder(stranger);
        vm.prank(admin);
        factory.reinstateForwarder(address(forwarder));
        vm.prank(solverBot);
        assertEq(forwarder.solveAndForward(ids, false), 1);
    }

    function testPausersPauseRegistrationsAndOnlyTheAdministratorResumesThem() public {
        vm.prank(operator);
        address pendingEngine = factory.deployEngine(_nextJob(), _engineParams());
        (VedaEngine engine,,) = _createStack(STACK_A);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotPauser.selector, operator));
        factory.pauseRegistrations();
        vm.prank(pauser);
        factory.pauseRegistrations();
        assertTrue(factory.registrationsPaused());

        vm.startPrank(operator);
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_B), address(0));
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.deployEngine(_nextJob(), _engineParams());
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.finalizeStack(pendingEngine, _coreParams(STACK_B), address(0));
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.deployForwarder(address(engine));
        vm.stopPrank();

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, pauser));
        factory.resumeRegistrations();
        vm.prank(admin);
        factory.resumeRegistrations();
        vm.prank(operator);
        factory.finalizeStack(pendingEngine, _coreParams(STACK_B), address(0));
    }

    function testAClosedFactoryTakesNoNewStackAndStillServesTheStacksItHas() public {
        vm.prank(operator);
        address pendingEngine = factory.deployEngine(_nextJob(), _engineParams());
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        _deposit(earnVault, user, 100e6);

        vm.expectEmit(address(factory));
        emit ClosedToNewStacksChanged(true, admin);
        vm.prank(admin);
        factory.setClosedToNewStacks(true);
        assertTrue(factory.closedToNewStacks());
        assertFalse(factory.registrationsPaused());

        // No new engine and no new stack, an engine left pending included.
        uint256 engines = factory.engineCount();
        vm.startPrank(operator);
        vm.expectRevert(VedaStackFactory.FactoryClosedToNewStacks.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_B), address(0));
        vm.expectRevert(VedaStackFactory.FactoryClosedToNewStacks.selector);
        factory.deployEngine(_nextJob(), _engineParams());
        vm.expectRevert(VedaStackFactory.FactoryClosedToNewStacks.selector);
        factory.finalizeStack(pendingEngine, _coreParams(STACK_B), address(0));
        vm.stopPrank();
        assertEq(factory.engineCount(), engines);
        assertEq(uint256(factory.stack(pendingEngine).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertFalse(_canCall(pendingEngine, address(teller), ITeller.bulkDeposit.selector));

        // The vault changes its Queue and stock solver. The closed factory still builds the forwarder
        // its stack needs, and the queued path works on the new modules.
        (AuthedQueue newQueue, AuthedSolver newSolver) = _newExitRail(address(accountant));
        _rotate(teller, newQueue, newSolver);
        vm.prank(operator);
        address newForwarder = factory.deployForwarder(address(engine));
        vm.prank(stackOwner);
        engine.setAuthorizedForwarder(newForwarder, true);
        _activate(engine, earnVault);
        assertEq(address(engine.queue()), address(newQueue));
        assertTrue(factory.isEngineReady(address(engine)));
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 15e6);
        assertEq(_solve(VedaForwardingSolver(newForwarder), requestId), 1);
        assertEq(asset.balanceOf(user), 15e6);

        // Pausers keep their levers over a closed factory, and the administrator its restores.
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        vm.prank(admin);
        factory.reinstateEngine(address(engine));
        assertEq(_deposit(earnVault, user, 1e6), 1e6);

        // Opened again, it builds stacks as before.
        vm.expectEmit(address(factory));
        emit ClosedToNewStacksChanged(false, admin);
        vm.prank(admin);
        factory.setClosedToNewStacks(false);
        assertFalse(factory.closedToNewStacks());
        (, EarnVault secondVault,) = _createStack(STACK_B);
        assertEq(_deposit(secondVault, user, 5e6), 5e6);
    }

    function testAClosedFactoryFinishesAMigrationItAlreadyStartedAndStartsNoOther() public {
        (VedaEngine oldEngine, EarnVault earnVault,) = _migratableStack(STACK_A);
        _deposit(earnVault, user, 100e6);
        vm.startPrank(operator);
        address replacement = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        address setAside = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.stopPrank();

        vm.prank(admin);
        factory.setClosedToNewStacks(true);

        // No further candidate is deployed.
        uint256 engines = factory.engineCount();
        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.FactoryClosedToNewStacks.selector);
        factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        assertEq(factory.engineCount(), engines);

        // A pauser can still set a candidate aside, and a pause still stops a finalization.
        vm.prank(pauser);
        factory.discardEngine(setAside);
        vm.prank(stackOwner);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, setAside));
        factory.finalizeMigrationEngine(setAside);
        vm.prank(pauser);
        factory.pauseRegistrations();
        vm.prank(stackOwner);
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.finalizeMigrationEngine(replacement);
        vm.prank(admin);
        factory.resumeRegistrations();
        assertTrue(factory.closedToNewStacks());

        // The candidate deployed before closing is still the EarnVault operator's to finish, and only theirs.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotEarnVaultOperator.selector, operator, stackOwner));
        factory.finalizeMigrationEngine(replacement);
        vm.prank(stackOwner);
        address forwarder = factory.finalizeMigrationEngine(replacement);
        assertEq(uint256(factory.stack(replacement).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertTrue(factory.isEngineReady(replacement));
        assertTrue(VedaEngine(replacement).authorizedForwarder(forwarder));

        vm.prank(stackOwner);
        earnVault.migrateEngine(replacement, 100e6, 100e6);
        assertEq(earnVault.engine(), replacement);
        assertEq(oldEngine.totalShares(), 0);
        assertEq(VedaEngine(replacement).totalShares(), 100e6);
        assertEq(_deposit(earnVault, user, 1e6), 1e6);
    }

    function testTheAdministratorFixesTheOwnerOfEveryNewStack() public {
        address otherOwner = makeAddr("other owner");
        address[3] memory nonAdmins = [operator, pauser, stranger];
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, nonAdmins[i]));
            factory.setRequiredStackOwner(nonAdmins[i]);
        }
        vm.prank(admin);
        vm.expectRevert(VedaStackFactory.FactoryCannotBeOwner.selector);
        factory.setRequiredStackOwner(address(factory));
        assertEq(factory.requiredStackOwner(), address(0));

        vm.expectEmit(address(factory));
        emit RequiredStackOwnerChanged(address(0), stackOwner, admin);
        vm.prank(admin);
        factory.setRequiredStackOwner(stackOwner);

        // The operator can no longer build a stack for an owner of its choosing, in one call or two.
        EarnFactory.DeployParams memory wrong = _coreParams(STACK_A);
        wrong.owner = otherOwner;
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.StackOwnerNotAllowed.selector, otherOwner, stackOwner));
        factory.createStack(_nextJob(), _engineParams(), wrong, address(0));
        address pendingEngine = factory.deployEngine(_nextJob(), _engineParams());
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.StackOwnerNotAllowed.selector, otherOwner, stackOwner));
        factory.finalizeStack(pendingEngine, wrong, address(0));
        assertEq(uint256(factory.stack(pendingEngine).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertFalse(_canCall(pendingEngine, address(teller), ITeller.bulkDeposit.selector));
        EarnFactory.DeployParams memory right = _coreParams(STACK_A);
        right.controls.migrationMode = EngineMigrationMode.OperatorEnabled;
        (address earnVault_,) = factory.finalizeStack(pendingEngine, right, address(0));
        vm.stopPrank();
        EarnVault earnVault = EarnVault(earnVault_);
        VedaEngine engine = VedaEngine(pendingEngine);
        assertEq(earnVault.operator(), stackOwner);
        assertEq(engine.owner(), stackOwner);
        _deposit(earnVault, user, 100e6);

        // The pin is a rule for building. The owner can still hand a stack on, both seats, and the
        // factory has no say in it.
        vm.startPrank(stackOwner);
        earnVault.transferOperator(otherOwner);
        engine.transferOwnership(otherOwner);
        vm.stopPrank();
        vm.startPrank(otherOwner);
        earnVault.acceptOperator();
        engine.acceptOwnership();
        vm.stopPrank();
        assertEq(earnVault.operator(), otherOwner);
        assertEq(engine.owner(), otherOwner);
        assertEq(factory.requiredStackOwner(), stackOwner);
        assertTrue(factory.isEngineReady(address(engine)));
        assertEq(_deposit(earnVault, user, 1e6), 1e6);

        // A migration candidate goes to its EarnVault's current operator, whatever the pin says.
        vm.prank(operator);
        address replacement = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.prank(otherOwner);
        factory.finalizeMigrationEngine(replacement);
        assertEq(VedaEngine(replacement).owner(), otherOwner);
        factory.assertMigrationCurrent(replacement);

        // Changing the pin touches no stack already built; lifting it returns the choice to the operator.
        vm.expectEmit(address(factory));
        emit RequiredStackOwnerChanged(stackOwner, address(0), admin);
        vm.prank(admin);
        factory.setRequiredStackOwner(address(0));
        assertEq(engine.owner(), otherOwner);
        EarnFactory.DeployParams memory free = _coreParams(STACK_B);
        free.owner = otherOwner;
        vm.prank(operator);
        (address freeEngine,,) = factory.createStack(_nextJob(), _engineParams(), free, address(0));
        assertEq(VedaEngine(freeEngine).owner(), otherOwner);
    }

    function testAMigrationPreparedForAFormerOperatorIsCaughtBeforeThePoolMoves() public {
        address newOperator = makeAddr("new earn vault operator");
        (VedaEngine oldEngine, EarnVault earnVault,) = _migratableStack(STACK_A);
        _deposit(earnVault, user, 100e6);

        // Neither an ordinary engine nor a candidate that is still pending is a prepared migration.
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.MigrationTargetMissing.selector, address(oldEngine)));
        factory.assertMigrationCurrent(address(oldEngine));
        vm.prank(operator);
        address stale = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, stale));
        factory.assertMigrationCurrent(stale);

        vm.prank(stackOwner);
        factory.finalizeMigrationEngine(stale);
        factory.assertMigrationCurrent(stale);

        // The EarnVault changes hands before the pool moves. The candidate stays with the operator
        // who finalized it.
        vm.prank(stackOwner);
        earnVault.transferOperator(newOperator);
        vm.prank(newOperator);
        earnVault.acceptOperator();
        vm.expectRevert(
            abi.encodeWithSelector(VedaStackFactory.MigrationOwnerStale.selector, stale, stackOwner, newOperator)
        );
        factory.assertMigrationCurrent(stale);

        // Without the check nothing stops the new operator: the pool would sit in an engine the former
        // operator still administers.
        uint256 beforeMigration = vm.snapshotState();
        vm.prank(newOperator);
        earnVault.migrateEngine(stale, 100e6, 100e6);
        assertEq(earnVault.engine(), stale);
        assertEq(VedaEngine(stale).owner(), stackOwner);
        vm.revertToState(beforeMigration);
        assertEq(earnVault.engine(), address(oldEngine));

        // The way out: a pauser revokes the stale candidate and the new operator prepares its own.
        vm.prank(pauser);
        factory.revokeEngine(stale);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, stale));
        factory.assertMigrationCurrent(stale);
        vm.prank(operator);
        address replacement = factory.deployMigrationEngine(_nextJob(), _engineParams(), address(earnVault));
        vm.startPrank(newOperator);
        factory.finalizeMigrationEngine(replacement);
        factory.assertMigrationCurrent(replacement);
        earnVault.migrateEngine(replacement, 100e6, 100e6);
        vm.stopPrank();
        assertEq(earnVault.engine(), replacement);
        assertEq(VedaEngine(replacement).owner(), newOperator);
        assertEq(VedaEngine(replacement).totalShares(), 100e6);
        factory.assertMigrationCurrent(replacement);
    }

    function testOnlyTheAdministratorClosesAndOpensAFactory() public {
        address[3] memory nonAdmins = [operator, pauser, stranger];
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, nonAdmins[i]));
            factory.setClosedToNewStacks(true);
        }
        assertFalse(factory.closedToNewStacks());

        vm.prank(admin);
        factory.setClosedToNewStacks(true);
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, nonAdmins[i]));
            factory.setClosedToNewStacks(false);
        }
        assertTrue(factory.closedToNewStacks());
    }

    function testAPauseStillStopsAClosedFactorysForwarders() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        vm.prank(admin);
        factory.setClosedToNewStacks(true);
        vm.prank(pauser);
        factory.pauseRegistrations();

        // The incident lever is whole: one call stops everything the operator key can do.
        vm.startPrank(operator);
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.deployForwarder(address(engine));
        vm.expectRevert(VedaStackFactory.RegistrationsPaused.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_B), address(0));
        vm.stopPrank();

        // Resuming leaves the factory closed.
        vm.prank(admin);
        factory.resumeRegistrations();
        assertTrue(factory.closedToNewStacks());
        vm.startPrank(operator);
        assertTrue(factory.deployForwarder(address(engine)) != address(0));
        vm.expectRevert(VedaStackFactory.FactoryClosedToNewStacks.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_B), address(0));
        vm.stopPrank();
    }

    function testTheAdministratorMayAlsoPauseAndRevoke() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        vm.startPrank(admin);
        factory.revokeEngine(address(engine));
        factory.revokeForwarder(factory.stack(address(engine)).forwarder);
        factory.pauseRegistrations();
        vm.stopPrank();
        assertTrue(factory.registrationsPaused());
    }

    function testOnlyTheAdministratorReplacesTheOperator() public {
        address newOperator = makeAddr("rotated operator");
        address[3] memory nonAdmins = [operator, pauser, stranger];
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, nonAdmins[i]));
            factory.setOperator(newOperator);
        }
        vm.prank(admin);
        vm.expectRevert(VedaStackFactory.ZeroAddress.selector);
        factory.setOperator(address(0));

        vm.prank(admin);
        factory.setOperator(newOperator);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotOperator.selector, operator));
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        vm.prank(newOperator);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 1);
    }

    // ------------------------------------------------------------------
    // Transfer policy choice
    // ------------------------------------------------------------------

    function testTransferPolicyIsNoneExistingOrNewWithAGivenAdministrator() public {
        // None: the always-allow policy.
        (,, StackMockShareToken open) = _createStack(STACK_A);
        assertEq(open.transferPolicyId(), 1);

        // Existing: attached as given.
        address policyAdmin = makeAddr("policy admin");
        uint64 existing = StackMockTip403Registry(TIP403_REGISTRY_ADDRESS).createPolicy(policyAdmin, 0);
        EarnFactory.DeployParams memory params = _coreParams(STACK_B);
        params.transferPolicyId = existing;
        vm.prank(operator);
        (,, address protectedShare) = factory.createStack(_nextJob(), _engineParams(), params, address(0));
        assertEq(StackMockShareToken(protectedShare).transferPolicyId(), existing);

        // New: a whitelist created for the given administrator and attached in the same call.
        address newAdmin = makeAddr("new policy admin");
        vm.expectEmit(true, true, false, false, address(factory));
        emit TransferPolicyCreated(existing + 1, newAdmin);
        vm.prank(operator);
        (,, address freshShare) =
            factory.createStack(_nextJob(), _engineParams(), _coreParams(keccak256("stack-c")), newAdmin);
        assertEq(StackMockShareToken(freshShare).transferPolicyId(), existing + 1);
        (uint8 policyType, address administrator) =
            StackMockTip403Registry(TIP403_REGISTRY_ADDRESS).policyData(existing + 1);
        assertEq(policyType, 0);
        assertEq(administrator, newAdmin);

        // Both at once is refused rather than guessed.
        params = _coreParams(keccak256("stack-d"));
        params.transferPolicyId = existing;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.AmbiguousTransferPolicy.selector, existing, newAdmin));
        factory.createStack(_nextJob(), _engineParams(), params, newAdmin);
    }

    /// @dev Publishes `unadmitted` while the Earn stacks have no access to it.
    function _publishUnadmittedTeller(AuthedTeller unadmitted) internal virtual;

    /// @dev As the administrator: takes the Earn forwarders' access to the published stock solver away.
    function _dropForwarderAccess() internal virtual;

    /// @dev Deploys another factory from `config` and has the administrator name it.
    function _newBoundFactory(VedaStackFactory.Config memory config) internal returns (VedaStackFactory other) {
        other = new VedaStackFactory(config);
        vm.prank(admin);
        _nameFactory(other);
    }

    /// @dev Called as the administrator: names `other` on the fixture's authorizer.
    function _nameFactory(VedaStackFactory other) internal virtual;

    /// @dev Called as the administrator: stops naming `other`.
    function _unnameFactory(VedaStackFactory other) internal virtual;

    /// @dev The error the authorizer raises for a factory wired to another registry or authorizer.
    function _notWiredSelector() internal pure virtual returns (bytes4);

    /// @dev A second registry for the same vault, which the administrator never published on.
    function _newLookalikeRegistry() internal virtual returns (address);
}

contract VedaRoleStackFactoryTest is VedaRoleStackTestBase, VedaStackFactoryBehavior {
    function setUp() public override(VedaStackTestBase) {
        super.setUp();
    }

    function _publishUnadmittedTeller(AuthedTeller unadmitted) internal override {
        // The Earn engine role was given no capability on this Teller.
        _publish(unadmitted, queue, solver);
    }

    function _dropForwarderAccess() internal override {
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            EARN_FORWARDER_ROLE, address(solver), IBoringSolver.boringRedeemSolve.selector, false
        );
    }

    function _nameFactory(VedaStackFactory other) internal override {
        granter.setFactory(address(other), true);
    }

    function _unnameFactory(VedaStackFactory other) internal override {
        granter.setFactory(address(other), false);
    }

    function _notWiredSelector() internal pure override returns (bytes4) {
        return VedaRoleGranter.FactoryNotWired.selector;
    }

    function _newLookalikeRegistry() internal override returns (address) {
        return address(new VedaVaultRegistry(IBoringVault(address(vault)), address(asset)));
    }
}
// forge-lint: disable-end(multi-contract-file)
