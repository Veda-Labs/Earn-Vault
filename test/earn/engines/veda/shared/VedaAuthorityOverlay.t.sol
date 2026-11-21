// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// The read-only overlay and the access registry behind it: what they add to the RolesAuthority's
// answers, what they can never add, and that they cannot fail in a way that strands the vault.
// forge-lint: disable-start(multi-contract-file,unsafe-typecast)
import { Vm } from "forge-std/Vm.sol";
import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { VedaForwardingSolver } from "../../../../../src/earn/engines/veda/VedaForwardingSolver.sol";
import { VedaAuthorityOverlay } from "../../../../../src/earn/engines/veda/shared/VedaAuthorityOverlay.sol";
import { VedaLockstepEngine } from "../../../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaVaultAccessRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultAccessRegistry.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IVedaStackAccess } from "../../../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { IAuth, IAuthority } from "../../../../../src/interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import {
    AuthedBoringVault,
    AuthedQueue,
    AuthedSolver,
    AuthedTeller,
    MockRolesAuthority
} from "../../../helpers/VedaAuthMocks.sol";
import { StackMockShareToken } from "../../../helpers/VedaStackMocks.sol";
import { VedaOverlayStackTestBase } from "../../../helpers/VedaStackTestBase.sol";

/// @dev A registry answer that is not a well-formed boolean.
contract MalformedAccess {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 0x20)
        }
    }
}

/// @dev A registry answer of the wrong length.
contract ShortAccess {
    fallback() external {
        assembly ("memory-safe") {
            mstore8(0, 1)
            return(0, 1)
        }
    }
}

contract VedaAuthorityOverlayTest is VedaOverlayStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");

    VedaLockstepEngine internal engine;
    EarnVault internal earnVault;
    StackMockShareToken internal earnShare;
    address internal forwarder;

    function setUp() public override {
        super.setUp();
        (engine, earnVault, earnShare) = _createStack(STACK_A);
        forwarder = factory.stack(address(engine)).forwarder;
    }

    // ------------------------------------------------------------------
    // Rule 1: everything the RolesAuthority allows stays allowed
    // ------------------------------------------------------------------

    function testFuzzWhateverTheRolesAuthorityAllowsTheOverlayAllows(
        address caller,
        address target,
        bytes4 functionSig,
        uint8 role,
        bool makePublic
    ) public {
        vm.startPrank(admin);
        if (makePublic) {
            rolesAuthority.setPublicCapability(target, functionSig, true);
        } else {
            rolesAuthority.setRoleCapability(role, target, functionSig, true);
            rolesAuthority.setUserRole(caller, role, true);
        }
        vm.stopPrank();
        assertTrue(rolesAuthority.canCall(caller, target, functionSig));
        assertTrue(overlay.canCall(caller, target, functionSig));
    }

    function testFuzzOutsideTheVaultsModulesTheOverlayAnswersExactlyAsTheRolesAuthority(
        address caller,
        address target,
        bytes4 functionSig
    ) public view {
        vm.assume(target != address(teller) && target != address(queue) && target != address(solver));
        assertEq(overlay.canCall(caller, target, functionSig), rolesAuthority.canCall(caller, target, functionSig));
    }

    function testTheVaultsOwnRolesKeepWorkingThroughTheOverlay() public view {
        // The stock solver, the Queue's callback and the engines already live all pass through rule 1.
        assertTrue(overlay.canCall(address(solver), address(teller), ITeller.bulkWithdraw.selector));
        assertTrue(overlay.canCall(address(solver), address(queue), AuthedQueue.solveOnChainWithdraws.selector));
        assertTrue(overlay.canCall(address(queue), address(solver), AuthedSolver.boringSolve.selector));
        assertTrue(overlay.canCall(legacyEngine, address(teller), ITeller.bulkDeposit.selector));
        assertTrue(overlay.canCall(admin, address(teller), IAuth.setAuthority.selector));
    }

    // ------------------------------------------------------------------
    // Rules 2 to 4: the fixed Earn calls
    // ------------------------------------------------------------------

    function testFuzzAnActiveEngineGetsExactlyItsFourCalls(bytes4 functionSig) public view {
        bool tellerCall = functionSig == ITeller.bulkDeposit.selector || functionSig == ITeller.bulkWithdraw.selector;
        bool queueCall = functionSig == IBoringQueue.requestOnChainWithdraw.selector
            || functionSig == IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector;
        assertEq(overlay.canCall(address(engine), address(teller), functionSig), tellerCall);
        assertEq(overlay.canCall(address(engine), address(queue), functionSig), queueCall);
        assertFalse(overlay.canCall(address(engine), address(solver), functionSig));
    }

    function testFuzzAnActiveForwarderGetsExactlyTheStockSolve(bytes4 functionSig) public view {
        assertEq(
            overlay.canCall(forwarder, address(solver), functionSig),
            functionSig == IBoringSolver.boringRedeemSolve.selector
        );
        assertFalse(overlay.canCall(forwarder, address(teller), functionSig));
        assertFalse(overlay.canCall(forwarder, address(queue), functionSig));
    }

    function testFuzzAnAccountTheFactoryNeverRecordedGetsNothing(address account, bytes4 functionSig) public view {
        vm.assume(account != address(engine) && account != forwarder);
        address[3] memory modules = [address(teller), address(queue), address(solver)];
        for (uint256 i = 0; i < modules.length; i++) {
            assertEq(
                overlay.canCall(account, modules[i], functionSig),
                rolesAuthority.canCall(account, modules[i], functionSig)
            );
        }
    }

    function testFuzzNoRecordEverAnswersForTheBoringVault(address account, bytes4 functionSig) public view {
        assertFalse(accessRegistry.canStackCall(account, address(vault), functionSig));
        assertFalse(accessRegistry.canStackCall(address(engine), address(vault), functionSig));
        assertFalse(accessRegistry.canStackCall(forwarder, address(vault), functionSig));
    }

    function testCustodyStaysBehindTheRolesAuthorityAlone() public {
        // The three repointed contracts answer to the overlay; the BoringVault does not.
        assertEq(teller.authority(), address(overlay));
        assertEq(queue.authority(), address(overlay));
        assertEq(solver.authority(), address(overlay));
        assertEq(vault.authority(), address(rolesAuthority));

        // Even a vault mistakenly pointed at the overlay would open no custody function to a stack.
        vm.prank(admin);
        vault.setAuthority(address(overlay));
        bytes4[] memory custody = _custodySelectors();
        address[4] memory accounts = [address(engine), forwarder, address(factory), address(accessRegistry)];
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < custody.length; j++) {
                assertFalse(overlay.canCall(accounts[i], address(vault), custody[j]));
            }
        }
        // The Teller still mints and burns for the stacks, because rule 1 passes its own roles through.
        assertEq(_deposit(earnVault, user, 10e6), 10e6);
    }

    function testNothingEverWritesToTheRolesAuthority() public {
        vm.startStateDiffRecording();
        (VedaLockstepEngine second,,) = _createStack(keccak256("stack-b"));
        vm.prank(pauser);
        factory.revokeEngine(address(second));
        vm.prank(admin);
        factory.reinstateEngine(address(second));
        address secondForwarder = factory.stack(address(second)).forwarder;
        vm.prank(pauser);
        factory.revokeForwarder(secondForwarder);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        for (uint256 i = 0; i < accesses.length; i++) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j = 0; j < storageAccesses.length; j++) {
                bool wroteRolesAuthority =
                    storageAccesses[j].account == address(rolesAuthority) && storageAccesses[j].isWrite;
                assertFalse(wroteRolesAuthority);
            }
        }
        assertEq(rolesAuthority.getUserRoles(address(second)), bytes32(0));
    }

    // ------------------------------------------------------------------
    // It must never fail
    // ------------------------------------------------------------------

    function testABrokenRegistryDeniesTheStacksAndNothingElse() public {
        _deposit(earnVault, user, 10e6);
        // A registry that reverts, one that answers with a word that is no boolean, and one that answers
        // with a single byte.
        bytes[3] memory brokenCode =
            [bytes(hex"5f5ffd"), address(new MalformedAccess()).code, address(new ShortAccess()).code];

        for (uint256 i = 0; i < brokenCode.length; i++) {
            vm.etch(address(accessRegistry), brokenCode[i]);

            // The stacks are denied without the overlay reverting...
            assertFalse(overlay.canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
            assertFalse(overlay.canCall(forwarder, address(solver), IBoringSolver.boringRedeemSolve.selector));
            // ...and everything that worked before the overlay still works.
            assertTrue(overlay.canCall(legacyEngine, address(teller), ITeller.bulkDeposit.selector));
            assertTrue(overlay.canCall(address(solver), address(teller), ITeller.bulkWithdraw.selector));
            assertTrue(overlay.canCall(admin, address(teller), IAuth.setAuthority.selector));
            asset.mint(legacyEngine, 1e6);
            vm.startPrank(legacyEngine);
            asset.approve(address(vault), 1e6);
            teller.bulkDeposit(address(asset), 1e6, 0, legacyEngine);
            vm.stopPrank();
        }

        // Above all, the administrator can still repoint the three contracts away from the overlay.
        vm.startPrank(admin);
        teller.setAuthority(address(rolesAuthority));
        queue.setAuthority(address(rolesAuthority));
        solver.setAuthority(address(rolesAuthority));
        vm.stopPrank();
        assertEq(teller.authority(), address(rolesAuthority));
    }

    function testAnAnswerOtherThanAWellFormedTrueIsADenial() public {
        // Only the exact word 1 admits; a nonzero word that is not a boolean does not.
        VedaAuthorityOverlay malformed = new VedaAuthorityOverlay(
            IAuthority(address(rolesAuthority)), IVedaStackAccess(address(new MalformedAccess()))
        );
        assertFalse(malformed.canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
        assertTrue(malformed.canCall(legacyEngine, address(teller), ITeller.bulkDeposit.selector));
    }

    function testTheOverlayHasNoStateAndValidatesItsWiring() public {
        assertEq(address(overlay.rolesAuthority()), address(rolesAuthority));
        assertEq(address(overlay.registry()), address(accessRegistry));
        // No owner, no setter and no storage: slot zero and its neighbours are empty.
        for (uint256 slot = 0; slot < 4; slot++) {
            assertEq(vm.load(address(overlay), bytes32(slot)), bytes32(0));
        }

        IVedaStackAccess access = IVedaStackAccess(address(accessRegistry));
        vm.expectRevert(VedaAuthorityOverlay.ZeroAddress.selector);
        new VedaAuthorityOverlay(IAuthority(address(0)), access);
        vm.expectRevert(VedaAuthorityOverlay.ZeroAddress.selector);
        new VedaAuthorityOverlay(IAuthority(address(rolesAuthority)), IVedaStackAccess(address(0)));
        vm.expectRevert(abi.encodeWithSelector(VedaAuthorityOverlay.InvalidOverlayWiring.selector, stranger));
        new VedaAuthorityOverlay(IAuthority(stranger), access);
        vm.expectRevert(abi.encodeWithSelector(VedaAuthorityOverlay.InvalidOverlayWiring.selector, stranger));
        new VedaAuthorityOverlay(IAuthority(address(rolesAuthority)), IVedaStackAccess(stranger));
    }

    // ------------------------------------------------------------------
    // The record: who writes it
    // ------------------------------------------------------------------

    function testOnlyTheNamedFactoryWritesTheRecord() public {
        address[5] memory callers = [stranger, operator, admin, pauser, address(overlay)];
        for (uint256 i = 0; i < callers.length; i++) {
            bytes memory notFactory =
                abi.encodeWithSelector(VedaVaultAccessRegistry.NotStackFactory.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(notFactory);
            accessRegistry.setEngineAuthorized(callers[i], true);
            vm.expectRevert(notFactory);
            accessRegistry.setEngineAuthorized(address(engine), false);
            vm.expectRevert(notFactory);
            accessRegistry.setForwarderAuthorized(callers[i], true);
            vm.expectRevert(notFactory);
            accessRegistry.setForwarderAuthorized(forwarder, false);
            vm.stopPrank();
        }
        assertTrue(accessRegistry.isActiveEngine(address(engine)));

        // A key is never recorded, even by the factory.
        vm.startPrank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.InvalidStackAccount.selector, stranger));
        accessRegistry.setEngineAuthorized(stranger, true);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.InvalidStackAccount.selector, stranger));
        accessRegistry.setForwarderAuthorized(stranger, true);
        vm.stopPrank();
    }

    function testWithNoFactoryNamedNoOneWritesTheRecordAndExistingStacksKeepWorking() public {
        vm.prank(admin);
        accessRegistry.setFactory(address(factory), false);

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.NotStackFactory.selector, address(0)));
        accessRegistry.setEngineAuthorized(address(engine), false);
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.NotStackFactory.selector, address(factory)));
        accessRegistry.setEngineAuthorized(address(engine), false);

        assertEq(_deposit(earnVault, user, 10e6), 10e6);
    }

    function testOnlyTheAdministratorNamesTheFactoryAndTheOverlay() public {
        address[4] memory callers = [stranger, operator, pauser, address(factory)];
        for (uint256 i = 0; i < callers.length; i++) {
            bytes memory notAdmin = abi.encodeWithSelector(VedaVaultRegistry.NotVaultAdmin.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(notAdmin);
            accessRegistry.setFactory(callers[i], true);
            vm.expectRevert(notAdmin);
            accessRegistry.setFactory(address(factory), false);
            vm.expectRevert(notAdmin);
            accessRegistry.setOverlay(address(0));
            vm.expectRevert(notAdmin);
            accessRegistry.setQueueHonored(IBoringQueue(address(queue)), false);
            vm.expectRevert(notAdmin);
            accessRegistry.setSolverHonored(IBoringSolver(address(solver)), true);
            vm.expectRevert(notAdmin);
            accessRegistry.revokeAccess(address(engine));
            vm.stopPrank();
        }
        // Only a contract that reports this registry as its registry and its authorizer is named.
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.InvalidStackAccount.selector, stranger));
        accessRegistry.setFactory(stranger, true);
        vm.expectRevert();
        accessRegistry.setFactory(address(teller), true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // The overlay binding and publications
    // ------------------------------------------------------------------

    function testTheRegistryCreatesItsOwnOverlayForAnyoneAtAPredictableAddress() public {
        assertTrue(accessRegistry.isRegistryOverlay(address(overlay)));
        assertEq(accessRegistry.predictOverlay(address(rolesAuthority)), address(overlay));
        assertEq(address(overlay.rolesAuthority()), address(rolesAuthority));
        assertEq(address(overlay.registry()), address(accessRegistry));

        // Asking again returns the same overlay; a second one cannot be made for the same RolesAuthority.
        vm.prank(stranger);
        assertEq(accessRegistry.createOverlay(), address(overlay));

        // A fresh registry reports where its overlay will be before it exists.
        VedaVaultAccessRegistry other = new VedaVaultAccessRegistry(IBoringVault(address(vault)), address(asset));
        address predicted = other.predictOverlay(address(rolesAuthority));
        assertEq(predicted.code.length, 0);
        assertFalse(other.isRegistryOverlay(predicted));
        assertEq(other.createOverlay(), predicted);
        assertTrue(other.isRegistryOverlay(predicted));
        assertTrue(predicted != address(overlay));
    }

    function testOnlyAnOverlayTheRegistryCreatedIsBound() public {
        // Identical code and wiring, deployed by someone else: the registry cannot vouch for it.
        address lookalike = address(
            new VedaAuthorityOverlay(IAuthority(address(rolesAuthority)), IVedaStackAccess(address(accessRegistry)))
        );
        VedaVaultAccessRegistry other = new VedaVaultAccessRegistry(IBoringVault(address(vault)), address(asset));
        address othersOverlay = other.createOverlay();

        vm.startPrank(admin);
        address[3] memory refused = [stranger, lookalike, othersOverlay];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.InvalidOverlay.selector, refused[i]));
            accessRegistry.setOverlay(refused[i]);
        }
        vm.stopPrank();
        assertEq(accessRegistry.overlay(), address(overlay));
    }

    function testAnOverlayIsBoundOnlyWhileThePublishedModulesAnswerToIt() public {
        vm.startPrank(admin);
        accessRegistry.setOverlay(address(0));
        teller.setAuthority(address(rolesAuthority));
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaVaultAccessRegistry.ModuleNotOnOverlay.selector,
                address(teller),
                address(overlay),
                address(rolesAuthority)
            )
        );
        accessRegistry.setOverlay(address(overlay));

        teller.setAuthority(address(overlay));
        accessRegistry.setOverlay(address(overlay));
        vm.stopPrank();
        assertEq(accessRegistry.overlay(), address(overlay));
    }

    function testAnOverlayForARolesAuthorityTheVaultHasLeftIsRefused() public {
        // The vault moves to a new RolesAuthority, owned by the same timelock. The bound overlay still
        // passes the old one through, so publications stop until the modules sit behind a new overlay.
        MockRolesAuthority replacement = new MockRolesAuthority(admin, address(0));
        vm.prank(admin);
        vault.setAuthority(address(replacement));

        bytes memory mismatch = abi.encodeWithSelector(
            VedaVaultAccessRegistry.OverlayRolesAuthorityMismatch.selector,
            address(overlay),
            address(rolesAuthority),
            address(replacement)
        );
        // The Teller needs its vault roles on the new RolesAuthority before anything can be published.
        vm.startPrank(admin);
        replacement.setRoleCapability(MINTER_ROLE, address(vault), vault.enter.selector, true);
        replacement.setRoleCapability(BURNER_ROLE, address(vault), vault.exit.selector, true);
        replacement.setUserRole(address(teller), MINTER_ROLE, true);
        replacement.setUserRole(address(teller), BURNER_ROLE, true);
        vm.stopPrank();
        vm.expectRevert(mismatch);
        _publish(teller, queue, solver);

        vm.startPrank(admin);
        accessRegistry.setOverlay(address(0));
        vm.expectRevert(mismatch);
        accessRegistry.setOverlay(address(overlay));
        vm.stopPrank();

        // The registry makes a different overlay for the new RolesAuthority.
        address newOverlay = accessRegistry.createOverlay();
        assertTrue(newOverlay != address(overlay));
        assertEq(address(VedaAuthorityOverlay(newOverlay).rolesAuthority()), address(replacement));
    }

    function testAPublicationIsRefusedUnlessEveryModuleAnswersToTheOverlay() public {
        // A Teller, a Queue or a stock solver left on the RolesAuthority would stop every stack at once.
        AuthedTeller newTeller = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        (AuthedQueue newQueue, AuthedSolver newSolver) = _newExitRail(address(accountant));
        vm.startPrank(admin);
        _grantTellerVaultRoles(newTeller);
        _grantStockSolverRoles(newTeller, newQueue, newSolver);
        vm.stopPrank();

        _expectNotOnOverlay(address(newTeller));
        _publishRaw(newTeller, queue, solver);

        _pointAtOverlayAsAdmin(address(newTeller));
        _expectNotOnOverlay(address(newQueue));
        _publishRaw(newTeller, newQueue, newSolver);

        _pointAtOverlayAsAdmin(address(newQueue));
        _expectNotOnOverlay(address(newSolver));
        _publishRaw(newTeller, newQueue, newSolver);

        _pointAtOverlayAsAdmin(address(newSolver));
        _publishRaw(newTeller, newQueue, newSolver);
        assertEq(address(accessRegistry.teller()), address(newTeller));
        assertEq(accessRegistry.version(), 2);
    }

    function testAReplacedQueueAndSolverStayHonoredUntilTheAdministratorRetiresThem() public {
        _deposit(earnVault, user, 100e6);
        bytes32 oldRequest = _requestRedeem(earnVault, earnShare, user, 10e6);
        bytes32 keptRequest = _requestRedeem(earnVault, earnShare, user, 5e6);

        (AuthedQueue newQueue, AuthedSolver newSolver) = _newExitRail(address(accountant));
        _rotate(teller, newQueue, newSolver);
        assertTrue(accessRegistry.isHonoredQueue(address(queue)));
        assertTrue(accessRegistry.isHonoredSolver(address(solver)));
        assertTrue(accessRegistry.isHonoredQueue(address(newQueue)));
        assertTrue(accessRegistry.isHonoredSolver(address(newSolver)));

        // Requests on the replaced Queue still cancel and still settle.
        vm.prank(user);
        earnVault.cancelRedeem(keptRequest, 1);
        assertEq(_solve(VedaForwardingSolver(forwarder), oldRequest), 1);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);

        // The published rail cannot be retired; the drained one can.
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.StillPublished.selector, address(newQueue)));
        accessRegistry.setQueueHonored(IBoringQueue(address(newQueue)), false);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.StillPublished.selector, address(newSolver)));
        accessRegistry.setSolverHonored(IBoringSolver(address(newSolver)), false);
        accessRegistry.setQueueHonored(IBoringQueue(address(queue)), false);
        accessRegistry.setSolverHonored(IBoringSolver(address(solver)), false);
        vm.stopPrank();

        assertFalse(overlay.canCall(address(engine), address(queue), IBoringQueue.requestOnChainWithdraw.selector));
        assertFalse(overlay.canCall(forwarder, address(solver), IBoringSolver.boringRedeemSolve.selector));
        assertTrue(overlay.canCall(address(engine), address(newQueue), IBoringQueue.requestOnChainWithdraw.selector));
        // The stock solver's own roles on the retired rail are the RolesAuthority's and are untouched.
        assertTrue(overlay.canCall(address(solver), address(queue), AuthedQueue.solveOnChainWithdraws.selector));
    }

    function testARailRetiredTooEarlyCanBeHonoredAgainSoItsRequestsAreNotStranded() public {
        _deposit(earnVault, user, 100e6);
        bytes32 strandedRequest = _requestRedeem(earnVault, earnShare, user, 10e6);
        (AuthedQueue newQueue, AuthedSolver newSolver) = _newExitRail(address(accountant));
        _rotate(teller, newQueue, newSolver);

        // Retired with a request still open: it can neither be cancelled nor settled.
        vm.startPrank(admin);
        accessRegistry.setQueueHonored(IBoringQueue(address(queue)), false);
        accessRegistry.setSolverHonored(IBoringSolver(address(solver)), false);
        vm.stopPrank();
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        vm.prank(user);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        earnVault.cancelRedeem(strandedRequest, 1);

        // The administrator undoes it without republishing the old Queue for new requests.
        vm.startPrank(admin);
        accessRegistry.setQueueHonored(IBoringQueue(address(queue)), true);
        accessRegistry.setSolverHonored(IBoringSolver(address(solver)), true);
        vm.stopPrank();
        assertEq(address(accessRegistry.queue()), address(newQueue));
        assertEq(_solve(VedaForwardingSolver(forwarder), strandedRequest), 1);
        assertEq(asset.balanceOf(user), 10e6);
    }

    function testOnlyAQueueOfThisVaultOrAContractCanBeHonored() public {
        AuthedBoringVault otherVault = new AuthedBoringVault(address(0), address(rolesAuthority), 6);
        AuthedQueue foreignQueue = new AuthedQueue(address(0), address(rolesAuthority), otherVault, address(accountant));
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaVaultRegistry.InvalidVedaPeripheryWiring.selector,
                address(foreignQueue),
                address(vault),
                address(otherVault)
            )
        );
        accessRegistry.setQueueHonored(IBoringQueue(address(foreignQueue)), true);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, stranger));
        accessRegistry.setQueueHonored(IBoringQueue(stranger), true);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, stranger));
        accessRegistry.setSolverHonored(IBoringSolver(stranger), true);
        vm.stopPrank();
    }

    function testTheAdministratorClearsAnyEntryDirectlyEvenOneAnotherFactoryWrote() public {
        // The factory that recorded this stack is no longer named, so its pausers cannot reach it.
        vm.prank(admin);
        accessRegistry.setFactory(address(factory), false);
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultAccessRegistry.NotStackFactory.selector, address(factory)));
        factory.revokeEngine(address(engine));

        vm.startPrank(admin);
        accessRegistry.revokeAccess(address(engine));
        accessRegistry.revokeAccess(forwarder);
        // Clearing is all it does: an unrecorded account stays unrecorded.
        accessRegistry.revokeAccess(stranger);
        vm.stopPrank();
        assertFalse(accessRegistry.isActiveEngine(address(engine)));
        assertFalse(accessRegistry.isActiveForwarder(forwarder));
        assertFalse(accessRegistry.isActiveEngine(stranger));
        assertFalse(overlay.canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
        assertFalse(overlay.canCall(forwarder, address(solver), IBoringSolver.boringRedeemSolve.selector));
    }

    function testARevokedEngineLosesEveryStackCallAtOnce() public {
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertFalse(accessRegistry.isActiveEngine(address(engine)));
        assertFalse(overlay.canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
        assertFalse(overlay.canCall(address(engine), address(teller), ITeller.bulkWithdraw.selector));
        assertFalse(
            overlay.canCall(address(engine), address(queue), IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector)
        );
        // Its forwarding solver is a separate record.
        assertTrue(overlay.canCall(forwarder, address(solver), IBoringSolver.boringRedeemSolve.selector));
    }

    function _expectNotOnOverlay(address module) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaVaultAccessRegistry.ModuleNotOnOverlay.selector, module, address(overlay), address(rolesAuthority)
            )
        );
    }

    function _publishRaw(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) private {
        _publish(teller_, queue_, solver_);
    }

    function _pointAtOverlayAsAdmin(address module) private {
        vm.startPrank(admin);
        _pointAtOverlay(module);
        vm.stopPrank();
    }
}
// forge-lint: disable-end(multi-contract-file,unsafe-typecast)
