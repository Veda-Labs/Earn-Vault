// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// A vault whose Teller is open to every caller and admits by account. There a role proves nothing and
// revoking one stops nothing, so these tests pin down that the granter, with its allowlist flag set,
// lists each engine as the factory builds it, that a stack is reported built only once the Teller's
// list admits it, that revoking a stack delists it wherever it could still be used, and that the same
// granter serves a Teller without a list while the flag is clear.
// forge-lint: disable-start(multi-contract-file,unsafe-typecast)
import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { VedaEngine } from "../../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaForwardingSolver } from "../../../../../src/earn/engines/veda/VedaForwardingSolver.sol";
import { VedaRoleGranter } from "../../../../../src/earn/engines/veda/shared/VedaRoleGranter.sol";
import { VedaStackFactory } from "../../../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { VedaTellerAllowlist } from "../../../../../src/earn/engines/veda/shared/VedaTellerAllowlist.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IVedaVaultRegistry } from "../../../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAccountant } from "../../../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { IRolesAuthority } from "../../../../../src/interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import { ITellerAllowlist } from "../../../../../src/interfaces/external/veda/ITellerAllowlist.sol";
import {
    AllowlistQueue,
    AllowlistTeller,
    AuthedBoringVault,
    AuthedQueue,
    AuthedSolver,
    AuthedTeller
} from "../../../helpers/VedaAuthMocks.sol";
import { StackMockShareToken } from "../../../helpers/VedaStackMocks.sol";
import { VedaAllowlistStackTestBase, VedaRoleStackTestBase } from "../../../helpers/VedaStackTestBase.sol";
import { VedaRoleStackHandler } from "./VedaRoleGranter.t.sol";

/// @dev A Teller that accepts a listing and records nothing.
contract ForgetfulTeller is AuthedTeller {
    uint256 public listingCalls;

    constructor(address owner_, address authority_, AuthedBoringVault vault_, address accountant_)
        AuthedTeller(owner_, authority_, vault_, accountant_)
    { }

    function setAllowedAccounts(address[] calldata, bool) external requiresAuth {
        listingCalls++;
    }

    function allowedAccounts(address) external pure returns (bool) {
        return false;
    }

    function isDepositAllowed(address) external pure returns (bool) {
        return true;
    }

    function isWithdrawAllowed(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Answers every call the way it is told to: what a module that is not the expected Teller or
///      Queue might return.
contract Shapeshifter {
    enum Shape {
        Reverts,
        Word,
        TwoWords,
        Nothing
    }

    Shape public shape;
    uint256 public word;

    function set(Shape shape_, uint256 word_) external {
        shape = shape_;
        word = word_;
    }

    fallback() external {
        Shape current = shape;
        uint256 value = word;
        if (current == Shape.Reverts) revert("NO");
        if (current == Shape.Nothing) return;
        bytes memory result = current == Shape.Word ? abi.encode(value) : abi.encode(value, value);
        assembly ("memory-safe") {
            return(add(result, 0x20), mload(result))
        }
    }
}

contract AllowlistProbe {
    function deposit(address teller, address account) external view returns (bool, bool) {
        return VedaTellerAllowlist.tryIsDepositAllowed(teller, account);
    }

    function withdraw(address teller, address account) external view returns (bool, bool) {
        return VedaTellerAllowlist.tryIsWithdrawAllowed(teller, account);
    }

    function listed(address teller, address account) external view returns (bool, bool) {
        return VedaTellerAllowlist.tryAllowedAccounts(teller, account);
    }

    function tellerOf(address holder) external view returns (bool, address) {
        return VedaTellerAllowlist.tryTeller(holder);
    }
}

contract VedaRoleGranterAllowlistTest is VedaAllowlistStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");
    bytes32 internal constant STACK_B = keccak256("stack-b");
    /// @dev What the granter records for an engine revoked after it was listed.
    address internal constant DELISTED = address(1);

    AllowlistTeller internal listed;

    function setUp() public override {
        super.setUp();
        listed = AllowlistTeller(address(teller));
    }

    // ------------------------------------------------------------------
    // Building
    // ------------------------------------------------------------------

    function testBuildingAStackPutsItsEngineOnTheTellersListInTheSameCall() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);

        assertTrue(granter.tellerAllowlist());
        assertTrue(listed.allowedAccounts(address(engine)));
        assertEq(granter.listedOn(address(engine)), address(teller));
        assertTrue(rolesAuthority.doesUserHaveRole(address(engine), EARN_ENGINE_ROLE));
        assertTrue(factory.isEngineReady(address(engine)));
        // A forwarding solver never holds vault shares, so it is not listed.
        assertFalse(listed.allowedAccounts(address(forwarder)));
        assertEq(granter.listedOn(address(forwarder)), address(0));

        // The stack works end to end the moment it exists: deposit, instant exit, queued exit.
        assertEq(_deposit(earnVault, user, 100e6), 100e6);
        vm.startPrank(user);
        earnShare.approve(address(earnVault), 40e6);
        assertEq(earnVault.redeem(40e6, receiver, 40e6), 40e6);
        vm.stopPrank();
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 25e6);
        assertEq(_solve(forwarder, requestId), 1);
        assertEq(asset.balanceOf(user), 25e6);
        assertEq(vault.balanceOf(address(engine)), 35e6);
    }

    function testWhereAnyoneMayCallTheTellerTheListIsWhatAdmits() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);

        // The Teller's own authority admits every caller...
        assertTrue(_canCall(stranger, address(teller), ITeller.bulkDeposit.selector));
        assertTrue(_canCall(stranger, address(teller), ITeller.bulkWithdraw.selector));
        // ...so the list alone stands between an account and the vault's lock-free paths.
        asset.mint(stranger, 1e6);
        vm.startPrank(stranger);
        asset.approve(address(vault), 1e6);
        vm.expectRevert(bytes("NOT_ALLOWED"));
        teller.bulkDeposit(address(asset), 1e6, 0, stranger);
        vm.expectRevert(bytes("NOT_ALLOWED"));
        teller.bulkWithdraw(address(asset), 1, 0, stranger);
        vm.stopPrank();

        // The administrator can change the list directly. The stack's record does not follow, which is
        // why readiness is read from the Teller and not from the record.
        _setListedDirectly(listed, address(engine), false);
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertFalse(factory.isEngineReady(address(engine)));
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
    }

    function testWithTheFlagClearAnUnlistedEngineIsNeverReportedAsBuilt() public {
        // The same vault, and the administrator forgot to say its Teller admits by account. Every call
        // the factory checks is open to all, so the role proves nothing about an engine; the Teller's
        // list is what would refuse it, and the factory reads that whatever the flag says.
        vm.prank(admin);
        granter.setTellerAllowlist(false);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.TellerEnforcesList.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));

        vm.prank(operator);
        vm.expectPartialRevert(VedaStackFactory.NotListedOnTeller.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);

        // In two transactions, whoever keeps the Teller's list can list the engine in between.
        vm.prank(operator);
        address engine = factory.deployEngine(_nextJob(), _engineParams());
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotListedOnTeller.selector, engine, address(teller)));
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0));
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Pending));

        _setListedDirectly(listed, engine, true);
        vm.prank(operator);
        (address earnVault,) = factory.finalizeStack(engine, _coreParams(STACK_A), address(0));
        assertTrue(factory.isEngineReady(engine));
        assertEq(granter.listedOn(engine), address(0));
        assertEq(_deposit(EarnVault(earnVault), user, 10e6), 10e6);
    }

    function testAStackIsNotBuiltWhenTheGranterCannotWriteTheTellersList() public {
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        vm.prank(operator);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);
    }

    function testTheFlagCannotBeLeftSetOverATellerThatKeepsNoList() public {
        AuthedTeller plain = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        vm.startPrank(admin);
        _grantTellerVaultRoles(plain);
        _grantEarnRoleCapabilities(plain, AuthedQueue(address(0)), AuthedSolver(address(0)));
        _grantListerCapability(plain);
        vm.stopPrank();
        _publish(plain, AuthedQueue(address(0)), AuthedSolver(address(0)));

        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.CannotListOnTeller.selector, address(plain)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        vm.prank(operator);
        vm.expectRevert();
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);

        // With the flag cleared the same granter serves it through the engine role alone.
        vm.prank(admin);
        granter.setTellerAllowlist(false);
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        assertEq(granter.listedOn(address(engine)), address(0));
        assertTrue(factory.isEngineReady(address(engine)));
        assertEq(_deposit(earnVault, user, 10e6), 10e6);
    }

    function testAListingTheTellerDidNotRecordIsRefused() public {
        ForgetfulTeller forgetful = new ForgetfulTeller(address(0), address(rolesAuthority), vault, address(accountant));
        vm.startPrank(admin);
        _grantTellerVaultRoles(forgetful);
        _grantEarnRoleCapabilities(forgetful, AuthedQueue(address(0)), AuthedSolver(address(0)));
        _grantListerCapability(forgetful);
        vm.stopPrank();
        _publish(forgetful, AuthedQueue(address(0)), AuthedSolver(address(0)));

        vm.prank(operator);
        vm.expectPartialRevert(VedaRoleGranter.ListingFailed.selector);
        factory.createStack(_nextJob(), _engineParams(), _coreParams(STACK_A), address(0));
        assertEq(forgetful.listingCalls(), 0);
        assertEq(factory.engineCount(), 0);
    }

    // ------------------------------------------------------------------
    // Stopping a stack
    // ------------------------------------------------------------------

    function testRevokingDelistsAndStopsTheEngineWhereTakingItsRoleWouldNot() public {
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);
        _deposit(earnVault, user, 100e6);
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 10e6);

        vm.prank(pauser);
        factory.revokeEngine(address(engine));

        // Its role is gone, and the Teller still admits it as a caller, as it admits everyone.
        assertFalse(rolesAuthority.doesUserHaveRole(address(engine), EARN_ENGINE_ROLE));
        assertTrue(_canCall(address(engine), address(teller), ITeller.bulkDeposit.selector));
        assertTrue(_canCall(address(engine), address(teller), ITeller.bulkWithdraw.selector));
        // What stops it is the list.
        assertFalse(listed.allowedAccounts(address(engine)));
        assertEq(granter.listedOn(address(engine)), DELISTED);
        assertFalse(factory.isEngineReady(address(engine)));
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
        vm.startPrank(user);
        earnShare.approve(address(earnVault), 1e6);
        vm.expectRevert(bytes("NOT_ALLOWED"));
        earnVault.redeem(1e6, receiver, 1);
        vm.stopPrank();

        // The Queue applies the same list at settlement, so a request already queued waits too.
        vm.prank(forwarderOwner);
        forwarder.setAuthorizedSolver(solverBot, true);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = requestId;
        vm.prank(solverBot);
        vm.expectRevert(bytes("NOT_ALLOWED"));
        forwarder.solveAndForward(ids, false);

        // Nobody but the administrator, through the factory, brings it back.
        assertEq(_relist(address(engine)), 0);
        assertFalse(listed.allowedAccounts(address(engine)));

        vm.prank(admin);
        factory.reinstateEngine(address(engine));
        assertTrue(listed.allowedAccounts(address(engine)));
        assertEq(granter.listedOn(address(engine)), address(teller));
        assertTrue(factory.isEngineReady(address(engine)));
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(solverBot);
        assertEq(forwarder.solveAndForward(ids, false), 1);
        assertEq(asset.balanceOf(user) - balanceBefore, 10e6);
        assertEq(_deposit(earnVault, user, 1e6), 1e6);
    }

    function testAnotherStackKeepsItsPlaceOnTheListThroughARevocation() public {
        (VedaEngine engineA,,) = _createStack(STACK_A);
        (VedaEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));

        assertFalse(listed.allowedAccounts(address(engineA)));
        assertTrue(listed.allowedAccounts(address(engineB)));
        assertTrue(listed.allowedAccounts(address(solver)));
        assertEq(_deposit(vaultB, user, 5e6), 5e6);
    }

    function testADelistingTheAdministratorMadeOnTheTellerIsNotUndoneByRelist() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        _setListedDirectly(listed, address(engine), false);

        // The granter's record still names this Teller, and it already listed the engine there.
        assertEq(granter.listedOn(address(engine)), address(teller));
        assertEq(_relist(address(engine)), 0);
        assertFalse(listed.allowedAccounts(address(engine)));
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
    }

    function testRevokingRemovesTheRoleAndTheListingEvenWhenTheOtherCannotBeRemoved() public {
        (VedaEngine engineA,,) = _createStack(STACK_A);
        (VedaEngine engineB,,) = _createStack(STACK_B);

        // The granter loses its permission on the Teller: the role is still taken away, and the engine
        // is recorded as revoked so that nothing can carry it to another Teller.
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        vm.expectEmit(true, true, false, true, address(granter));
        emit VedaRoleGranter.EngineDelistingDeferred(address(engineA), address(teller));
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));
        assertEq(uint256(factory.stack(address(engineA)).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        assertFalse(rolesAuthority.doesUserHaveRole(address(engineA), EARN_ENGINE_ROLE));
        assertEq(granter.listedOn(address(engineA)), DELISTED);
        assertTrue(listed.allowedAccounts(address(engineA)));

        // Once the Teller can be written again, anyone finishes the delisting.
        vm.prank(admin);
        _grantListerCapability(teller);
        vm.prank(stranger);
        assertEq(granter.redelist(_one(address(engineA))), 1);
        assertFalse(listed.allowedAccounts(address(engineA)));

        // The granter is cut off from the RolesAuthority: the engine is still delisted, which is what
        // stops it on this vault, and its role is left for the administrator.
        vm.prank(admin);
        rolesAuthority.setAuthority(address(0));
        vm.expectEmit(true, false, false, true, address(granter));
        emit VedaRoleGranter.EngineRoleRevocationDeferred(address(engineB));
        vm.prank(pauser);
        factory.revokeEngine(address(engineB));
        assertFalse(listed.allowedAccounts(address(engineB)));
        assertTrue(rolesAuthority.doesUserHaveRole(address(engineB), EARN_ENGINE_ROLE));
        // The role it kept does not make it eligible for the list again.
        assertEq(_relist(address(engineB)), 0);
    }

    function testARevocationStandsWhenNeitherTheRoleNorTheListingCanBeRemovedYet() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        vm.startPrank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        rolesAuthority.setAuthority(address(0));
        vm.stopPrank();

        // Neither the role nor the Teller's entry can be removed now. The granter still records the
        // engine as revoked, so the revocation is not lost: nothing can carry the engine to another
        // Teller, and anyone finishes the delisting once the Teller can be written.
        vm.expectEmit(true, false, false, true, address(granter));
        emit VedaRoleGranter.EngineRoleRevocationDeferred(address(engine));
        vm.expectEmit(true, true, false, true, address(granter));
        emit VedaRoleGranter.EngineDelistingDeferred(address(engine), address(teller));
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        assertEq(granter.listedOn(address(engine)), DELISTED);
        assertEq(_relist(address(engine)), 0);
        // Until then the engine still works, which the events say.
        assertTrue(listed.allowedAccounts(address(engine)));
        assertEq(_deposit(earnVault, user, 1e6), 1e6);

        vm.prank(admin);
        _grantListerCapability(teller);
        vm.prank(stranger);
        assertEq(granter.redelist(_one(address(engine))), 1);
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
    }

    function testARevokedEngineIsTakenOffATellerItReachedAnotherWay() public {
        (VedaEngine engineA, EarnVault vaultA,) = _createStack(STACK_A);
        (VedaEngine engineB,,) = _createStack(STACK_B);

        // The administrator schedules a new Teller with both engines already on its list...
        (AllowlistTeller next, AuthedQueue nextQueue, AuthedSolver nextSolver) = _nextModules();
        vm.startPrank(admin);
        _grantTellerVaultRoles(next);
        _grantStockSolverRoles(next, nextQueue, nextSolver);
        _admitModules(next, nextQueue, nextSolver);
        next.setAllowedAccounts(_two(address(engineA), address(engineB)), true);
        vm.stopPrank();
        // ...a pauser revokes one of them before it is published...
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));
        assertFalse(listed.allowedAccounts(address(engineA)));
        _publish(next, nextQueue, nextSolver);

        // ...so the new Teller, which the engine's owner could activate, admits an engine that is
        // recorded as revoked, and a pauser cannot revoke it a second time.
        assertTrue(next.allowedAccounts(address(engineA)));
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, address(engineA)));
        factory.revokeEngine(address(engineA));

        // Anyone takes it off; an engine that is still authorized, and an account the granter never
        // listed, are left alone.
        address[] memory accounts = new address[](3);
        accounts[0] = address(engineA);
        accounts[1] = address(engineB);
        accounts[2] = address(solver);
        vm.prank(stranger);
        assertEq(granter.redelist(accounts), 1);
        assertFalse(next.allowedAccounts(address(engineA)));
        assertTrue(next.allowedAccounts(address(engineB)));
        assertTrue(listed.allowedAccounts(address(engineB)));
        assertTrue(listed.allowedAccounts(address(solver)));
        _activate(engineA, vaultA);
        _expectDepositRefused(vaultA, "NOT_ALLOWED");
    }

    function testRevokingAnEngineStopsItOnTheTellerItUsesAndOnTheOneItCouldActivate() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        (AllowlistTeller next, AuthedQueue nextQueue, AuthedSolver nextSolver) = _nextModules();
        _rotate(next, nextQueue, nextSolver);
        assertEq(_relist(address(engine)), 1);

        // The engine is on both lists and still uses the first Teller.
        assertEq(address(engine.teller()), address(teller));
        assertEq(granter.listedOn(address(engine)), address(next));
        assertTrue(listed.allowedAccounts(address(engine)));
        assertTrue(next.allowedAccounts(address(engine)));

        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertFalse(listed.allowedAccounts(address(engine)));
        assertFalse(next.allowedAccounts(address(engine)));
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
        // Activating the publication does not bring it back.
        _activate(engine, earnVault);
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
        assertFalse(factory.isEngineReady(address(engine)));
    }

    function testForwarderReadinessFollowsTheTellersListToo() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);
        vm.prank(forwarderOwner);
        forwarder.setAuthorizedSolver(solverBot, true);
        assertTrue(factory.isForwarderReady(address(forwarder), solverBot));

        // The stock solver redeems every settled request, so it must be on the list...
        _setListedDirectly(listed, address(solver), false);
        assertFalse(factory.isForwarderReady(address(forwarder), solverBot));
        _setListedDirectly(listed, address(solver), true);
        // ...and the Queue settles nothing for an engine that is not.
        _setListedDirectly(listed, address(engine), false);
        assertFalse(factory.isForwarderReady(address(forwarder), solverBot));
        _setListedDirectly(listed, address(engine), true);
        assertTrue(factory.isForwarderReady(address(forwarder), solverBot));
    }

    function testAQueueThatAppliesNoListKeepsSettlingForADelistedEngine() public {
        // The registry publishes such a vault; the granter's setup assertion is what refuses it.
        (VedaEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);
        _deposit(earnVault, user, 100e6);
        bytes32 requestId = _requestRedeem(earnVault, earnShare, user, 10e6);
        vm.prank(admin);
        AllowlistQueue(address(queue)).setTeller(address(0));

        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertEq(_solve(forwarder, requestId), 1);
        assertEq(asset.balanceOf(user), 10e6);
    }

    // ------------------------------------------------------------------
    // A new Teller
    // ------------------------------------------------------------------

    function testANewlyPublishedTellerIsListedBeforeAnEngineActivatesIt() public {
        (VedaEngine engineA, EarnVault vaultA, StackMockShareToken shareA) = _createStack(STACK_A);
        (VedaEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        (VedaEngine engineC,,) = _createStack(keccak256("stack-c"));
        (VedaEngine engineD, EarnVault vaultD,) = _createStack(keccak256("stack-d"));
        _deposit(vaultA, user, 10e6);
        vm.prank(pauser);
        factory.revokeEngine(address(engineC));

        (AllowlistTeller next, AuthedQueue nextQueue, AuthedSolver nextSolver) = _nextModules();
        _rotate(next, nextQueue, nextSolver);

        // A publication moves no engine: each keeps the Teller it was built on, and keeps working.
        assertEq(address(engineA.teller()), address(teller));
        assertTrue(factory.isEngineReady(address(engineA)));
        assertEq(_deposit(vaultA, user, 1e6), 1e6);
        assertFalse(next.allowedAccounts(address(engineA)));

        // Anyone carries the engines that hold the engine role onto the new list; one revoked engine
        // in the batch does not fail it, and an engine named twice is written once.
        address[] memory engines = new address[](4);
        engines[0] = address(engineA);
        engines[1] = address(engineC);
        engines[2] = address(engineB);
        engines[3] = address(engineA);
        vm.prank(stranger);
        assertEq(granter.relist(engines), 2);
        assertTrue(next.allowedAccounts(address(engineA)));
        assertTrue(next.allowedAccounts(address(engineB)));
        assertFalse(next.allowedAccounts(address(engineC)));
        // Their places on the Teller they still use are untouched.
        assertTrue(listed.allowedAccounts(address(engineA)));
        assertTrue(listed.allowedAccounts(address(engineB)));

        // A revoked engine, and an account that never was an engine, stay off the new list, and an
        // engine already carried is not written twice.
        engines = new address[](2);
        engines[0] = address(engineC);
        engines[1] = stranger;
        assertEq(granter.relist(engines), 0);
        assertEq(_relist(address(engineA)), 0);
        assertFalse(next.allowedAccounts(stranger));

        // The owner of a carried engine activates the publication, with a forwarding solver for the
        // new Queue, and the stack works on the new modules: deposit, queued exit.
        vm.prank(operator);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.deployForwarder(address(engineA)));
        vm.prank(stackOwner);
        engineA.setAuthorizedForwarder(address(forwarder), true);
        _activate(engineA, vaultA);
        assertEq(address(engineA.teller()), address(next));
        assertTrue(factory.isEngineReady(address(engineA)));
        assertEq(_deposit(vaultA, user, 1e6), 1e6);
        assertEq(next.bulkDepositCalls(), 1);
        bytes32 requestId = _requestRedeem(vaultA, shareA, user, 5e6);
        assertEq(_solve(forwarder, requestId), 1);
        assertEq(vaultB.totalAssets(), 0);

        // An engine activated before it was carried is refused by the new Teller until it is.
        _activate(engineD, vaultD);
        assertFalse(factory.isEngineReady(address(engineD)));
        _expectDepositRefused(vaultD, "NOT_ALLOWED");
        assertEq(_relist(address(engineD)), 1);
        assertTrue(factory.isEngineReady(address(engineD)));
        assertEq(_deposit(vaultD, user, 1e6), 1e6);

        // A new stack is built on, and listed on, the Teller published now.
        (VedaEngine engineE,,) = _createStack(keccak256("stack-e"));
        assertEq(address(engineE.teller()), address(next));
        assertTrue(next.allowedAccounts(address(engineE)));
        assertFalse(listed.allowedAccounts(address(engineE)));
    }

    function testRelistCarriesOnlyContractsThatHoldTheEngineRole() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        (AllowlistTeller next, AuthedQueue nextQueue, AuthedSolver nextSolver) = _nextModules();
        _rotate(next, nextQueue, nextSolver);

        // The administrator can give the engine role to any account directly. A key that holds it is
        // never listed; a contract that holds it is, since the role is what admits an engine.
        Shapeshifter roleHolder = new Shapeshifter();
        vm.startPrank(admin);
        rolesAuthority.setUserRole(stranger, EARN_ENGINE_ROLE, true);
        rolesAuthority.setUserRole(address(roleHolder), EARN_ENGINE_ROLE, true);
        vm.stopPrank();

        address[] memory accounts = new address[](5);
        accounts[0] = stranger;
        accounts[1] = address(roleHolder);
        accounts[2] = address(engine);
        accounts[3] = address(factory);
        accounts[4] = legacyEngine;
        vm.prank(stranger);
        assertEq(granter.relist(accounts), 2);
        assertFalse(next.allowedAccounts(stranger));
        assertTrue(next.allowedAccounts(address(roleHolder)));
        assertTrue(next.allowedAccounts(address(engine)));
        assertFalse(next.allowedAccounts(address(factory)));
        assertFalse(next.allowedAccounts(legacyEngine));

        // An engine whose role the administrator took away directly is not carried any further.
        vm.prank(admin);
        rolesAuthority.setUserRole(address(engine), EARN_ENGINE_ROLE, false);
        (AllowlistTeller third, AuthedQueue thirdQueue, AuthedSolver thirdSolver) = _nextModules();
        _rotate(third, thirdQueue, thirdSolver);
        assertEq(_relist(address(engine)), 0);
        assertFalse(third.allowedAccounts(address(engine)));
    }

    function testPublishingRefusesAQueueBoundToAnotherTellersListOrASolverThatIsNotOnIt() public {
        AllowlistTeller next = AllowlistTeller(address(_newTeller()));
        vm.startPrank(admin);
        _grantTellerVaultRoles(next);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(next), AllowlistTeller.setAllowlistEnabled.selector, true);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(next), ITellerAllowlist.setAllowedAccounts.selector, true);
        next.setAllowlistEnabled(true, true);

        // The Queue still applies the outgoing Teller's list to its request owners.
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaVaultRegistry.QueueTellerMismatch.selector, address(queue), address(next), address(teller)
            )
        );
        _publishAsCaller(next);

        // Bound to the new list, on which the stock solver could not redeem a settled request.
        AllowlistQueue(address(queue)).setTeller(address(next));
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.SolverNotListedOnTeller.selector, address(solver), address(next))
        );
        _publishAsCaller(next);

        _list(next, address(solver));
        _publishAsCaller(next);
        assertEq(address(registry.teller()), address(next));

        // A Queue that applies no list at all is published as before.
        AllowlistQueue(address(queue)).setTeller(address(0));
        _publishAsCaller(next);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Who the granter answers to
    // ------------------------------------------------------------------

    function testOnlyTheRolesAuthoritysOwnerSetsTheFlag() public {
        address[4] memory others = [stranger, pauser, operator, stackOwner];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityOwner.selector, others[i]));
            granter.setTellerAllowlist(false);
        }
        assertTrue(granter.tellerAllowlist());

        (VedaEngine engine,,) = _createStack(STACK_A);
        vm.expectEmit(false, false, false, true, address(granter));
        emit VedaRoleGranter.TellerAllowlistChanged(false);
        vm.prank(admin);
        granter.setTellerAllowlist(false);
        // Clearing it changes no list and no record, and stops anyone carrying engines to a Teller.
        assertTrue(listed.allowedAccounts(address(engine)));
        assertEq(granter.listedOn(address(engine)), address(teller));
        vm.expectRevert(VedaRoleGranter.TellerAllowlistOff.selector);
        granter.relist(_one(address(engine)));

        // An engine listed while it was set is still delisted when it is revoked.
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertFalse(listed.allowedAccounts(address(engine)));
        assertEq(granter.listedOn(address(engine)), DELISTED);

        // Reinstated on a vault that no longer lists, it is eligible for the next Teller that does.
        vm.prank(admin);
        _setListedDirectlyAsCaller(listed, address(engine), true);
        vm.prank(admin);
        factory.reinstateEngine(address(engine));
        assertEq(granter.listedOn(address(engine)), address(0));
    }

    function testOnlyANamedFactoryListsOrDelistsThroughTheGranter() public {
        (VedaEngine engine,,) = _createStack(STACK_A);
        address[5] memory callers = [stranger, admin, operator, pauser, stackOwner];
        for (uint256 i = 0; i < callers.length; i++) {
            bytes memory notFactory = abi.encodeWithSelector(VedaRoleGranter.NotFactory.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(notFactory);
            granter.setEngineAuthorized(address(asset), true);
            vm.expectRevert(notFactory);
            granter.setEngineAuthorized(address(engine), false);
            vm.stopPrank();
        }
        assertTrue(listed.allowedAccounts(address(engine)));
        assertFalse(listed.allowedAccounts(address(asset)));

        // Anyone may ask for a delisting again, and it reaches only engines recorded as revoked.
        address[] memory accounts = _two(address(engine), address(solver));
        vm.prank(stranger);
        assertEq(granter.redelist(accounts), 0);
        assertTrue(listed.allowedAccounts(address(engine)));
        assertTrue(listed.allowedAccounts(address(solver)));
    }

    function testTheSetupAssertionChecksTheFlagAgainstThePublishedTeller() public {
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));

        // Without the Teller permission the setup batch must fail, not the first stack.
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.CannotListOnTeller.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));

        vm.startPrank(admin);
        _grantListerCapability(teller);
        // A list that is not enforced admits everyone, so listing would decide nothing.
        listed.setAllowlistEnabled(true, false);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.ListNotEnforced.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowlistEnabled(false, true);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.ListNotEnforced.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowlistEnabled(true, true);
        // A Queue that applies no list would keep serving a delisted engine.
        AllowlistQueue(address(queue)).setTeller(address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.QueueNotBound.selector, address(queue), address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        AllowlistQueue(address(queue)).setTeller(address(teller));
        // A stock solver that is not on the list could not redeem a settled request.
        listed.setAllowedAccounts(_one(address(solver)), false);
        vm.expectRevert(
            abi.encodeWithSelector(VedaRoleGranter.SolverNotListed.selector, address(solver), address(teller))
        );
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowedAccounts(_one(address(solver)), true);
        // A list anyone may write admits whoever wants in.
        rolesAuthority.setPublicCapability(address(teller), ITellerAllowlist.setAllowedAccounts.selector, true);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.ListWritableByAnyone.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        rolesAuthority.setPublicCapability(address(teller), ITellerAllowlist.setAllowedAccounts.selector, false);
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));

        // With the flag clear, a list enforced in either direction would refuse every engine.
        granter.setTellerAllowlist(false);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.TellerEnforcesList.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowlistEnabled(true, false);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.TellerEnforcesList.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowlistEnabled(false, true);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.TellerEnforcesList.selector, address(teller)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        // A Teller that keeps a list and enforces none of it is served by the role alone.
        listed.setAllowlistEnabled(false, false);
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        vm.stopPrank();
    }

    function testTheGrantersListerRoleReachesNothingButTheTellersList() public {
        _createStack(STACK_A);
        assertEq(rolesAuthority.getUserRoles(address(granter)), bytes32(uint256(1) << LISTER_ROLE));
        assertTrue(_canCall(address(granter), address(teller), ITellerAllowlist.setAllowedAccounts.selector));
        assertFalse(_canCall(address(granter), address(teller), AllowlistTeller.setAllowlistEnabled.selector));
        assertFalse(_canCall(address(granter), address(queue), AllowlistQueue.setTeller.selector));

        bytes4[] memory custody = _custodySelectors();
        for (uint256 i = 0; i < custody.length; i++) {
            assertFalse(_canCall(address(granter), address(vault), custody[i]));
        }
        // On the RolesAuthority it reaches `setUserRole`, as it always did, and nothing else.
        bytes4[] memory roleAdmin = _roleAdminSelectors();
        for (uint256 i = 0; i < roleAdmin.length; i++) {
            assertEq(
                _canCall(address(granter), address(rolesAuthority), roleAdmin[i]),
                roleAdmin[i] == IRolesAuthority.setUserRole.selector
            );
        }
    }

    function testReadingAListToleratesAModuleThatAnswersInAnotherShape() public {
        AllowlistProbe probe = new AllowlistProbe();
        Shapeshifter module = new Shapeshifter();

        // Anything but one word holding 0 or 1 is no answer, and never a revert.
        Shapeshifter.Shape[3] memory unreadable =
            [Shapeshifter.Shape.Reverts, Shapeshifter.Shape.TwoWords, Shapeshifter.Shape.Nothing];
        for (uint256 i = 0; i < unreadable.length; i++) {
            module.set(unreadable[i], 1);
            _assertUnreadable(probe, address(module));
        }
        _assertUnreadable(probe, stranger);
        // A word that is neither 0 nor 1 is not a yes or a no.
        module.set(Shapeshifter.Shape.Word, 2);
        _assertNoAnswer(probe, address(module));

        module.set(Shapeshifter.Shape.Word, 1);
        (bool supported, bool allowed) = probe.deposit(address(module), stranger);
        assertTrue(supported && allowed);
        module.set(Shapeshifter.Shape.Word, 0);
        (supported, allowed) = probe.withdraw(address(module), stranger);
        assertTrue(supported);
        assertFalse(allowed);

        // An address with dirty upper bits is not a Teller's address.
        module.set(Shapeshifter.Shape.Word, uint256(uint160(address(teller))) | (1 << 200));
        (supported,) = probe.tellerOf(address(module));
        assertFalse(supported);
        module.set(Shapeshifter.Shape.Word, uint256(uint160(address(teller))));
        (bool reports, address reported) = probe.tellerOf(address(module));
        assertTrue(reports);
        assertEq(reported, address(teller));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev A second Teller that admits by account, with a Queue bound to it and that Queue's solver.
    function _nextModules() private returns (AllowlistTeller next, AuthedQueue nextQueue, AuthedSolver nextSolver) {
        next = AllowlistTeller(address(_newTeller()));
        (nextQueue, nextSolver) = _newExitRail(address(accountant));
    }

    function _setListedDirectly(AllowlistTeller teller_, address account, bool allowed) private {
        vm.prank(admin);
        teller_.setAllowedAccounts(_one(account), allowed);
    }

    /// @dev Called inside the administrator's prank.
    function _setListedDirectlyAsCaller(AllowlistTeller teller_, address account, bool allowed) private {
        teller_.setAllowedAccounts(_one(account), allowed);
    }

    function _expectDepositRefused(EarnVault earnVault, string memory reason) private {
        asset.mint(user, 1e6);
        vm.startPrank(user);
        asset.approve(address(earnVault), 1e6);
        vm.expectRevert(bytes(reason));
        earnVault.deposit(1e6, user, 1);
        vm.stopPrank();
    }

    /// @dev Called inside the administrator's prank.
    function _publishAsCaller(AllowlistTeller teller_) private {
        registry.publish(
            ITeller(address(teller_)),
            IBoringQueue(address(queue)),
            IAccountant(address(accountant)),
            IBoringSolver(address(solver))
        );
    }

    function _assertNoAnswer(AllowlistProbe probe, address module) private view {
        (bool supported, bool value) = probe.deposit(module, stranger);
        assertFalse(supported || value);
        (supported, value) = probe.withdraw(module, stranger);
        assertFalse(supported || value);
        (supported, value) = probe.listed(module, stranger);
        assertFalse(supported || value);
    }

    function _assertUnreadable(AllowlistProbe probe, address module) private view {
        _assertNoAnswer(probe, module);
        (bool reports, address reported) = probe.tellerOf(module);
        assertFalse(reports);
        assertEq(reported, address(0));
    }

    function _one(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _two(address first, address second) private pure returns (address[] memory accounts) {
        accounts = new address[](2);
        accounts[0] = first;
        accounts[1] = second;
    }
}

/// @dev A vault that starts with a Teller that gates its callers and moves to one that admits by
///      account: the same granter and factory serve both, and the flag is what changes.
contract VedaTellerMigrationTest is VedaRoleStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");
    bytes32 internal constant STACK_B = keccak256("stack-b");

    function testAVaultMovesFromATellerThatGatesCallersToOneThatAdmitsByAccount() public {
        (VedaEngine engineA, EarnVault vaultA,) = _createStack(STACK_A);
        (VedaEngine engineC,,) = _createStack(keccak256("stack-c"));
        assertFalse(granter.tellerAllowlist());
        assertEq(granter.listedOn(address(engineA)), address(0));
        assertEq(_deposit(vaultA, user, 10e6), 10e6);
        // With the flag clear there is no list to carry anything to.
        vm.expectRevert(VedaRoleGranter.TellerAllowlistOff.selector);
        _relist(address(engineA));

        // The administrator's publication batch for the new kind of Teller.
        AllowlistTeller next = new AllowlistTeller(address(0), address(rolesAuthority), vault, address(accountant));
        AuthedQueue nextQueue = new AllowlistQueue(address(0), address(rolesAuthority), vault, address(accountant));
        AuthedSolver nextSolver = new AuthedSolver(address(0), address(rolesAuthority), nextQueue);
        vm.startPrank(admin);
        _grantTellerVaultRoles(next);
        _grantStockSolverRoles(next, nextQueue, nextSolver);
        _grantEarnRoleCapabilities(next, nextQueue, nextSolver);
        _configureAllowlist(next, nextQueue, nextSolver);
        _grantListerCapability(next);
        rolesAuthority.setUserRole(address(granter), LISTER_ROLE, true);
        registry.publish(
            ITeller(address(next)),
            IBoringQueue(address(nextQueue)),
            IAccountant(address(accountant)),
            IBoringSolver(address(nextSolver))
        );
        // Until the flag says so, the batch's last call refuses a Teller that would refuse every engine.
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.TellerEnforcesList.selector, address(next)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        granter.setTellerAllowlist(true);
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        vm.stopPrank();

        // The engine built before the flag was set holds the engine role, which is what carries it.
        assertEq(_relist(address(engineA)), 1);
        assertTrue(next.allowedAccounts(address(engineA)));
        assertEq(granter.listedOn(address(engineA)), address(next));

        // It keeps working on the Teller it was built on until its owner activates the new one.
        assertEq(_deposit(vaultA, user, 1e6), 1e6);
        assertEq(next.bulkDepositCalls(), 0);
        _activate(engineA, vaultA);
        assertEq(address(engineA.teller()), address(next));
        assertTrue(factory.isEngineReady(address(engineA)));
        assertEq(_deposit(vaultA, user, 1e6), 1e6);
        assertEq(next.bulkDepositCalls(), 1);

        // A stack built now is listed as it is built, and revoking either delists it.
        (VedaEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        assertTrue(next.allowedAccounts(address(engineB)));
        assertEq(_deposit(vaultB, user, 1e6), 1e6);
        vm.startPrank(pauser);
        factory.revokeEngine(address(engineA));
        factory.revokeEngine(address(engineB));
        vm.stopPrank();
        assertFalse(next.allowedAccounts(address(engineA)));
        assertFalse(next.allowedAccounts(address(engineB)));

        // An engine from before the flag that the administrator listed on the new Teller directly was
        // never listed by the granter. It holds the engine role, so revoking it still delists it, and
        // nobody can carry it back.
        vm.prank(admin);
        _list(next, address(engineC));
        assertEq(granter.listedOn(address(engineC)), address(0));
        vm.prank(pauser);
        factory.revokeEngine(address(engineC));
        assertFalse(next.allowedAccounts(address(engineC)));
        assertEq(granter.listedOn(address(engineC)), address(1));
        assertEq(_relist(address(engineC)), 0);
        // The stock solver, which a factory never authorized, stays where the administrator put it.
        assertTrue(next.allowedAccounts(address(nextSolver)));
    }

    function testOnATellerThatGatesCallersTheRoleAloneAdmitsAndNothingIsListed() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        assertEq(rolesAuthority.getUserRoles(address(granter)), bytes32(0));
        assertEq(granter.listedOn(address(engine)), address(0));
        assertTrue(factory.isEngineReady(address(engine)));

        // Revoking writes to no Teller, and nothing is recorded for a list that does not exist.
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertEq(granter.listedOn(address(engine)), address(0));
        assertFalse(factory.isEngineReady(address(engine)));
        asset.mint(user, 1e6);
        vm.startPrank(user);
        asset.approve(address(earnVault), 1e6);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        earnVault.deposit(1e6, user, 1);
        vm.stopPrank();
        address[] memory engines = new address[](1);
        engines[0] = address(engine);
        assertEq(granter.redelist(engines), 0);
    }
}

/// @dev Anyone tries to carry accounts onto the Teller's list or take them off it.
contract VedaTellerListHandler is Test {
    VedaRoleGranter public immutable granter;
    VedaRoleStackHandler public immutable stacks;
    address[] public actors;

    constructor(VedaRoleGranter granter_, VedaRoleStackHandler stacks_, address[] memory actors_) {
        granter = granter_;
        stacks = stacks_;
        actors = actors_;
    }

    function relist(uint256 actorSeed, uint256 accountSeed) external {
        address[] memory accounts = new address[](1);
        accounts[0] = _account(accountSeed);
        vm.prank(_actor(actorSeed));
        try granter.relist(accounts) { } catch { }
    }

    function redelist(uint256 actorSeed, uint256 accountSeed) external {
        address[] memory accounts = new address[](1);
        accounts[0] = _account(accountSeed);
        vm.prank(_actor(actorSeed));
        try granter.redelist(accounts) { } catch { }
    }

    /// @dev Only the administrator sets the flag; everyone else's attempt must change nothing.
    function setTellerAllowlist(uint256 actorSeed, bool enabled) external {
        address actor = _actor(actorSeed);
        if (granter.registry().isVaultAdmin(actor)) return;
        vm.prank(actor);
        try granter.setTellerAllowlist(enabled) { } catch { }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev An engine the factory deployed, when there is one, or else one of the actors.
    function _account(uint256 seed) private view returns (address) {
        uint256 engineCount = stacks.engineCount();
        if (engineCount != 0 && seed % 2 == 0) return stacks.engines((seed / 2) % engineCount);
        return actors[(seed / 2) % actors.length];
    }
}

contract VedaAllowlistStackInvariantTest is VedaAllowlistStackTestBase {
    VedaRoleStackHandler private stacks;
    VedaTellerListHandler private listHandler;
    address[] private _actors;
    AllowlistTeller private listed;

    function setUp() public override {
        super.setUp();
        listed = AllowlistTeller(address(teller));
        _actors = [operator, admin, pauser, stranger, stackOwner];
        stacks = new VedaRoleStackHandler(factory, granter, _actors);
        listHandler = new VedaTellerListHandler(granter, stacks, _actors);
        targetContract(address(stacks));
        targetContract(address(listHandler));
    }

    /// @dev The handlers' calls do land for their rightful callers, so the invariant below is checked
    ///      over listed, delisted and relisted engines and not over reverts alone.
    function testHandlerCallsLandForTheirRightfulCallers() public {
        stacks.createStack(0, stackOwner, address(0)); // operator
        address engine = stacks.engines(0);
        assertTrue(listed.allowedAccounts(engine));
        stacks.revokeOrReinstateEngine(2, 0, true); // pauser
        assertFalse(listed.allowedAccounts(engine));
        listHandler.relist(3, 0); // a stranger cannot bring it back
        assertFalse(listed.allowedAccounts(engine));
        stacks.revokeOrReinstateEngine(1, 0, false); // administrator
        assertTrue(listed.allowedAccounts(engine));
        listHandler.redelist(3, 0); // a stranger cannot delist it
        assertTrue(listed.allowedAccounts(engine));
        listHandler.setTellerAllowlist(3, false); // nor clear the flag
        assertTrue(granter.tellerAllowlist());
    }

    /// @dev Whatever anyone calls, the Teller's list holds the stock solver and exactly the engines
    ///      this factory records as active, and the granter's record says the same.
    function invariant_theTellersListIsTheStockSolverAndTheActiveEngines() public view {
        for (uint256 i = 0; i < stacks.engineCount(); i++) {
            address engine = stacks.engines(i);
            VedaStackFactory.EngineStatus status = factory.stack(engine).status;
            bool active = status == VedaStackFactory.EngineStatus.Active;
            assertEq(listed.allowedAccounts(engine), active);
            assertEq(rolesAuthority.doesUserHaveRole(engine, EARN_ENGINE_ROLE), active);
            assertEq(factory.isEngineReady(engine), active);
            address recorded = granter.listedOn(engine);
            if (active) assertEq(recorded, address(teller));
            else if (status == VedaStackFactory.EngineStatus.Revoked) assertEq(recorded, address(1));
            else assertEq(recorded, address(0));
        }
        for (uint256 i = 0; i < stacks.forwarderCount(); i++) {
            assertFalse(listed.allowedAccounts(stacks.forwarders(i)));
        }
        address[9] memory others = [
            admin,
            pauser,
            operator,
            stranger,
            stackOwner,
            legacyEngine,
            address(factory),
            address(granter),
            address(queue)
        ];
        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(listed.allowedAccounts(others[i]));
            assertEq(granter.listedOn(others[i]), address(0));
        }
        assertTrue(listed.allowedAccounts(address(solver)));
        assertTrue(granter.tellerAllowlist());

        // The granter holds its one role, which reaches no custody function.
        assertEq(rolesAuthority.getUserRoles(address(granter)), bytes32(uint256(1) << LISTER_ROLE));
        bytes4[] memory custody = _custodySelectors();
        for (uint256 i = 0; i < custody.length; i++) {
            assertFalse(rolesAuthority.doesRoleHaveCapability(LISTER_ROLE, address(vault), custody[i]));
        }
    }
}
// forge-lint: disable-end(multi-contract-file,unsafe-typecast)
