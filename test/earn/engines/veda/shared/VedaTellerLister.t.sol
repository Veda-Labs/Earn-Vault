// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// A vault whose Teller is open to every caller and admits by account. There a role proves nothing and
// revoking one stops nothing, so these tests pin down that the factory lists each engine as it builds
// it, reports a stack built only once the Teller's list admits it, and stops a stack by delisting it.
// forge-lint: disable-start(multi-contract-file,unsafe-typecast)
import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { VedaForwardingSolver } from "../../../../../src/earn/engines/veda/VedaForwardingSolver.sol";
import { VedaLockstepEngine } from "../../../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaStackFactory } from "../../../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { VedaTellerAllowlist } from "../../../../../src/earn/engines/veda/shared/VedaTellerAllowlist.sol";
import { VedaTellerLister } from "../../../../../src/earn/engines/veda/shared/VedaTellerLister.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import {
    IVedaStackAuthorizer,
    IVedaTellerLister,
    IVedaVaultRegistry
} from "../../../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAccountant } from "../../../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
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
import { VedaAllowlistStackTestBase } from "../../../helpers/VedaStackTestBase.sol";
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

/// @dev Reports a stack factory's wiring and relays whatever it is told to the lister: what a named
///      factory with different code could do.
contract WiredCaller {
    address public immutable authorizer;
    address public immutable tellerLister;
    address public immutable registry;

    constructor(address tellerLister_, address registry_) {
        tellerLister = tellerLister_;
        registry = registry_;
        authorizer = address(0);
    }

    function list(address account, bool listed) external {
        IVedaTellerLister(tellerLister).setEngineListed(account, listed);
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

    function queueTeller(address queue) external view returns (bool, address) {
        return VedaTellerAllowlist.tryQueueTeller(queue);
    }
}

contract VedaTellerListerTest is VedaAllowlistStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");
    bytes32 internal constant STACK_B = keccak256("stack-b");

    AllowlistTeller internal listed;

    function setUp() public override {
        super.setUp();
        listed = AllowlistTeller(address(teller));
    }

    // ------------------------------------------------------------------
    // Building
    // ------------------------------------------------------------------

    function testBuildingAStackPutsItsEngineOnTheTellersListInTheSameCall() public {
        (VedaLockstepEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
        VedaForwardingSolver forwarder = VedaForwardingSolver(factory.stack(address(engine)).forwarder);

        assertTrue(listed.allowedAccounts(address(engine)));
        assertTrue(lister.isListedEngine(address(engine)));
        assertTrue(factory.isEngineReady(address(engine)));
        // A forwarding solver never holds vault shares, so it is not listed.
        assertFalse(listed.allowedAccounts(address(forwarder)));

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
        (VedaLockstepEngine engine, EarnVault earnVault,) = _createStack(STACK_A);

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
        _setListedDirectly(address(engine), false);
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertFalse(factory.isEngineReady(address(engine)));
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
    }

    function testAFactoryWithoutAListerNeverReportsAnUnlistedEngineAsBuilt() public {
        // The same vault, and a factory that only grants roles. Every call it checks is open to all, so
        // the role proves nothing about its engine; the Teller's list is what would refuse it.
        VedaStackFactory.Config memory config = _factoryConfig();
        config.tellerLister = IVedaTellerLister(address(0));
        VedaStackFactory rolesOnly = new VedaStackFactory(config);
        vm.prank(admin);
        granter.setFactory(address(rolesOnly), true);

        vm.prank(operator);
        vm.expectPartialRevert(VedaStackFactory.NotListedOnTeller.selector);
        rolesOnly.createStack(_engineParams(), _coreParams(STACK_A), address(0));
        assertEq(rolesOnly.engineCount(), 0);

        // In two transactions, whoever keeps the Teller's list can list the engine in between.
        vm.prank(operator);
        address engine = rolesOnly.deployEngine(_engineParams());
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotListedOnTeller.selector, engine, address(teller)));
        rolesOnly.finalizeStack(engine, _coreParams(STACK_A), address(0));
        assertEq(uint256(rolesOnly.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Pending));

        _setListedDirectly(engine, true);
        vm.prank(operator);
        (address earnVault,) = rolesOnly.finalizeStack(engine, _coreParams(STACK_A), address(0));
        assertTrue(rolesOnly.isEngineReady(engine));
        assertEq(_deposit(EarnVault(earnVault), user, 10e6), 10e6);
    }

    function testAStackIsNotBuiltWhenTheListerCannotWriteTheTellersList() public {
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        vm.prank(operator);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        factory.createStack(_engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);
    }

    function testAListerCannotServeATellerThatKeepsNoList() public {
        AuthedTeller plain = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        vm.startPrank(admin);
        _grantTellerVaultRoles(plain);
        _grantEarnRoleCapabilities(plain, AuthedQueue(address(0)), AuthedSolver(address(0)));
        _grantListerCapability(plain);
        vm.stopPrank();
        _publish(plain, AuthedQueue(address(0)), AuthedSolver(address(0)));

        vm.prank(operator);
        vm.expectRevert();
        factory.createStack(_engineParams(), _coreParams(STACK_A), address(0));
        assertEq(factory.engineCount(), 0);
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
        vm.expectPartialRevert(VedaTellerLister.ListingFailed.selector);
        factory.createStack(_engineParams(), _coreParams(STACK_A), address(0));
        assertEq(forgetful.listingCalls(), 0);
        assertEq(factory.engineCount(), 0);
    }

    // ------------------------------------------------------------------
    // Stopping a stack
    // ------------------------------------------------------------------

    function testRevokingDelistsAndStopsTheEngineWhereTakingItsRoleWouldNot() public {
        (VedaLockstepEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
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
        assertFalse(lister.isListedEngine(address(engine)));
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

        vm.prank(admin);
        factory.reinstateEngine(address(engine));
        assertTrue(listed.allowedAccounts(address(engine)));
        assertTrue(lister.isListedEngine(address(engine)));
        assertTrue(factory.isEngineReady(address(engine)));
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(solverBot);
        assertEq(forwarder.solveAndForward(ids, false), 1);
        assertEq(asset.balanceOf(user) - balanceBefore, 10e6);
        assertEq(_deposit(earnVault, user, 1e6), 1e6);
    }

    function testAnotherStackKeepsItsPlaceOnTheListThroughARevocation() public {
        (VedaLockstepEngine engineA,,) = _createStack(STACK_A);
        (VedaLockstepEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));

        assertFalse(listed.allowedAccounts(address(engineA)));
        assertTrue(listed.allowedAccounts(address(engineB)));
        assertTrue(listed.allowedAccounts(address(solver)));
        assertEq(_deposit(vaultB, user, 5e6), 5e6);
    }

    function testRevokeListingIsTheAdministratorsAndRelistCannotUndoIt() public {
        (VedaLockstepEngine engine,,) = _createStack(STACK_A);
        address[3] memory nonAdmins = [stranger, pauser, operator];
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.NotVaultAdmin.selector, nonAdmins[i]));
            lister.revokeListing(address(engine));
        }

        vm.prank(admin);
        lister.revokeListing(address(engine));
        assertFalse(listed.allowedAccounts(address(engine)));
        assertFalse(lister.isListedEngine(address(engine)));
        // The factory's record is its own; readiness follows the Teller.
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertFalse(factory.isEngineReady(address(engine)));

        assertEq(lister.relist(_one(address(engine))), 0);
        assertFalse(listed.allowedAccounts(address(engine)));

        // Only an account the lister listed can be delisted through it.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.NotListedEngine.selector, address(solver)));
        lister.revokeListing(address(solver));
        assertTrue(listed.allowedAccounts(address(solver)));
    }

    function testADelistingTheAdministratorMadeOnTheTellerIsNotUndoneByRelist() public {
        (VedaLockstepEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        _setListedDirectly(address(engine), false);

        // The lister's record still says listed, and it already listed the engine on this Teller.
        assertTrue(lister.isListedEngine(address(engine)));
        vm.prank(stackOwner);
        assertEq(lister.relist(_one(address(engine))), 0);
        assertFalse(listed.allowedAccounts(address(engine)));
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
    }

    function testRevokingRemovesEachGateEvenWhenTheOtherCannotBeRemoved() public {
        (VedaLockstepEngine engineA,,) = _createStack(STACK_A);
        (VedaLockstepEngine engineB,,) = _createStack(STACK_B);

        // The lister loses its permission on the Teller: the role is still taken away, and the engine
        // is recorded as delisted so that nothing can carry it to another Teller.
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        vm.expectEmit(true, true, false, true, address(factory));
        emit VedaStackFactory.EngineRevocationIncomplete(address(engineA), address(lister));
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));
        assertEq(uint256(factory.stack(address(engineA)).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        assertFalse(rolesAuthority.doesUserHaveRole(address(engineA), EARN_ENGINE_ROLE));
        assertFalse(lister.isListedEngine(address(engineA)));
        assertTrue(listed.allowedAccounts(address(engineA)));

        // Once the Teller can be written again, anyone finishes the delisting.
        vm.prank(admin);
        _grantListerCapability(teller);
        vm.prank(stranger);
        assertEq(lister.redelist(_one(address(engineA))), 1);
        assertFalse(listed.allowedAccounts(address(engineA)));

        // The granter is cut off from the RolesAuthority: the engine is still delisted, which is what
        // stops it on this vault, and its role is left for the administrator.
        vm.prank(admin);
        rolesAuthority.setAuthority(address(0));
        vm.expectEmit(true, true, false, true, address(factory));
        emit VedaStackFactory.EngineRevocationIncomplete(address(engineB), address(granter));
        vm.prank(pauser);
        factory.revokeEngine(address(engineB));
        assertFalse(listed.allowedAccounts(address(engineB)));
        assertTrue(rolesAuthority.doesUserHaveRole(address(engineB), EARN_ENGINE_ROLE));
    }

    function testARevocationStandsWhenNeitherGateCanBeRemovedYet() public {
        (VedaLockstepEngine engine, EarnVault earnVault,) = _createStack(STACK_A);
        vm.startPrank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        rolesAuthority.setAuthority(address(0));
        vm.stopPrank();

        // Neither the role nor the Teller's entry can be removed now. The lister still records the
        // engine as delisted, so the revocation is not lost: nothing can carry the engine to another
        // Teller, and anyone finishes the delisting once the Teller can be written.
        vm.expectEmit(true, true, false, true, address(factory));
        emit VedaStackFactory.EngineRevocationIncomplete(address(engine), address(lister));
        vm.expectEmit(true, true, false, true, address(factory));
        emit VedaStackFactory.EngineRevocationIncomplete(address(engine), address(granter));
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertEq(uint256(factory.stack(address(engine)).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        assertFalse(lister.isListedEngine(address(engine)));
        assertEq(lister.relist(_one(address(engine))), 0);
        // Until then the engine still works, which the incomplete events say.
        assertTrue(listed.allowedAccounts(address(engine)));
        assertEq(_deposit(earnVault, user, 1e6), 1e6);

        vm.prank(admin);
        _grantListerCapability(teller);
        vm.prank(stranger);
        assertEq(lister.redelist(_one(address(engine))), 1);
        _expectDepositRefused(earnVault, "NOT_ALLOWED");
    }

    function testADelistedEngineIsTakenOffATellerItReachedAnotherWay() public {
        (VedaLockstepEngine engineA, EarnVault vaultA,) = _createStack(STACK_A);
        (VedaLockstepEngine engineB,,) = _createStack(STACK_B);

        // The administrator schedules a new Teller with both engines already on its list...
        AllowlistTeller next = AllowlistTeller(address(_newTeller()));
        vm.startPrank(admin);
        _grantTellerVaultRoles(next);
        _grantStockSolverRoles(next, queue, solver);
        _admitModules(next, queue, solver);
        next.setAllowedAccounts(_two(address(engineA), address(engineB)), true);
        vm.stopPrank();
        // ...a pauser revokes one of them before it is published...
        vm.prank(pauser);
        factory.revokeEngine(address(engineA));
        _publish(next, queue, solver);

        // ...so the new Teller admits an engine that is recorded as revoked, and a pauser cannot
        // revoke it a second time.
        assertTrue(next.allowedAccounts(address(engineA)));
        assertFalse(factory.isEngineReady(address(engineA)));
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotActive.selector, address(engineA)));
        factory.revokeEngine(address(engineA));

        // Anyone takes it off; an engine that is still listed, and an account the lister never
        // listed, are left alone.
        address[] memory accounts = new address[](3);
        accounts[0] = address(engineA);
        accounts[1] = address(engineB);
        accounts[2] = address(solver);
        vm.prank(stranger);
        assertEq(lister.redelist(accounts), 1);
        assertFalse(next.allowedAccounts(address(engineA)));
        assertTrue(next.allowedAccounts(address(engineB)));
        assertTrue(next.allowedAccounts(address(solver)));
        _expectDepositRefused(vaultA, "NOT_ALLOWED");

        // The same after a Teller is published again with the list it had: the first Teller never
        // saw a delisting of an engine revoked while the second was published.
        vm.prank(pauser);
        factory.revokeEngine(address(engineB));
        assertTrue(listed.allowedAccounts(address(engineB)));
        vm.prank(admin);
        AllowlistQueue(address(queue)).setTeller(address(teller));
        _publish(teller, queue, solver);
        // Both delisted engines are written off; the first Teller had already taken engine A's.
        assertEq(lister.redelist(accounts), 2);
        assertFalse(listed.allowedAccounts(address(engineB)));
        assertFalse(listed.allowedAccounts(address(engineA)));
        assertTrue(listed.allowedAccounts(address(solver)));
    }

    function testAQueueThatAppliesNoListKeepsSettlingForADelistedEngine() public {
        // The registry publishes such a vault; the lister's setup assertion is what refuses it.
        (VedaLockstepEngine engine, EarnVault earnVault, StackMockShareToken earnShare) = _createStack(STACK_A);
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

    function testANewlyPublishedTellerStartsWithoutTheVaultsEnginesUntilTheyAreRelisted() public {
        (VedaLockstepEngine engineA, EarnVault vaultA,) = _createStack(STACK_A);
        (VedaLockstepEngine engineB, EarnVault vaultB,) = _createStack(STACK_B);
        (VedaLockstepEngine engineC,,) = _createStack(keccak256("stack-c"));
        _deposit(vaultA, user, 10e6);
        _deposit(vaultB, user, 20e6);
        vm.prank(pauser);
        factory.revokeEngine(address(engineC));

        AllowlistTeller next = AllowlistTeller(address(_newTeller()));
        _rotate(next, queue, solver);

        // Every engine follows the publication at once, onto a list none of them is on.
        assertEq(address(engineA.teller()), address(next));
        assertFalse(factory.isEngineReady(address(engineA)));
        assertFalse(factory.isEngineReady(address(engineB)));
        _expectDepositRefused(vaultA, "NOT_ALLOWED");

        // Anyone carries the recorded engines over; nothing else can be carried.
        // One revoked engine in the batch does not fail it.
        address[] memory engines = new address[](4);
        engines[0] = address(engineA);
        engines[1] = address(engineC);
        engines[2] = address(engineB);
        engines[3] = address(engineA);
        vm.prank(stranger);
        assertEq(lister.relist(engines), 2);
        engines = new address[](2);
        assertTrue(next.allowedAccounts(address(engineA)));
        assertTrue(next.allowedAccounts(address(engineB)));
        assertTrue(factory.isEngineReady(address(engineA)));
        assertEq(_deposit(vaultA, user, 1e6), 1e6);
        assertEq(_deposit(vaultB, user, 1e6), 1e6);
        assertEq(next.bulkDepositCalls(), 2);

        // A revoked engine, and an account that never was an engine, stay off the new list, and an
        // engine already carried is not written twice.
        engines[0] = address(engineC);
        engines[1] = stranger;
        assertEq(lister.relist(engines), 0);
        assertEq(lister.relist(_one(address(engineA))), 0);
        assertFalse(next.allowedAccounts(address(engineC)));
        assertFalse(next.allowedAccounts(stranger));

        // A new stack is listed on the Teller published now.
        (VedaLockstepEngine engineD,,) = _createStack(keccak256("stack-d"));
        assertTrue(next.allowedAccounts(address(engineD)));
        assertFalse(listed.allowedAccounts(address(engineD)));
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
    // Who the lister answers to
    // ------------------------------------------------------------------

    function testOnlyANamedFactoryListsOrDelists() public {
        (VedaLockstepEngine engine,,) = _createStack(STACK_A);
        address[5] memory callers = [stranger, admin, operator, pauser, stackOwner];
        for (uint256 i = 0; i < callers.length; i++) {
            bytes memory notFactory = abi.encodeWithSelector(VedaTellerLister.NotFactory.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(notFactory);
            lister.setEngineListed(callers[i], true);
            vm.expectRevert(notFactory);
            lister.setEngineListed(address(engine), false);
            vm.stopPrank();
        }
        assertTrue(listed.allowedAccounts(address(engine)));

        // Once the administrator stops naming the factory, it lists and delists nothing more.
        vm.prank(admin);
        lister.setFactory(address(factory), false);
        assertFalse(factory.isAuthorizerBound());
        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.AuthorizerNotBound.selector);
        factory.createStack(_engineParams(), _coreParams(STACK_B), address(0));
        // A pauser still takes the engine's role away, and is told the listing stayed. The listing
        // is then the administrator's to revoke.
        vm.expectEmit(true, true, false, true, address(factory));
        emit VedaStackFactory.EngineRevocationIncomplete(address(engine), address(lister));
        vm.prank(pauser);
        factory.revokeEngine(address(engine));
        assertFalse(rolesAuthority.doesUserHaveRole(address(engine), EARN_ENGINE_ROLE));
        assertTrue(listed.allowedAccounts(address(engine)));
        assertTrue(lister.isListedEngine(address(engine)));
        vm.prank(admin);
        assertTrue(lister.revokeListing(address(engine)));
        assertFalse(listed.allowedAccounts(address(engine)));
    }

    function testOnlyTheAdministratorNamesAFactoryAndOnlyOneBuiltOnThisListerAndRegistry() public {
        address[3] memory nonAdmins = [stranger, pauser, operator];
        for (uint256 i = 0; i < nonAdmins.length; i++) {
            vm.prank(nonAdmins[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.NotVaultAdmin.selector, nonAdmins[i]));
            lister.setFactory(address(factory), true);
        }

        // A factory that lists through another lister.
        VedaStackFactory.Config memory config = _factoryConfig();
        config.tellerLister = IVedaTellerLister(address(new VedaTellerLister(IVedaVaultRegistry(address(registry)))));
        VedaStackFactory elsewhere = new VedaStackFactory(config);
        // A factory that builds on a registry the administrator never published on.
        config = _factoryConfig();
        config.registry =
            IVedaVaultRegistry(address(new VedaVaultRegistry(IBoringVault(address(vault)), address(asset))));
        VedaStackFactory misdirected = new VedaStackFactory(config);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.FactoryNotWired.selector, address(elsewhere)));
        lister.setFactory(address(elsewhere), true);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.FactoryNotWired.selector, address(misdirected)));
        lister.setFactory(address(misdirected), true);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.FactoryNotWired.selector, stranger));
        lister.setFactory(stranger, true);
        // A contract that is no stack factory at all.
        vm.expectRevert();
        lister.setFactory(address(asset), true);
        // Unnaming needs no wiring.
        lister.setFactory(stranger, false);
        vm.stopPrank();
        assertFalse(lister.isFactory(address(elsewhere)));
        assertFalse(lister.isFactory(address(misdirected)));
    }

    function testANamedFactoryIsTrustedForWhatItListsButNeverAKeyOrAnEmptyAddress() public {
        // The lister cannot tell an engine from any other contract: naming a factory is trusting its
        // code. What it can refuse is an account that is no contract.
        WiredCaller wired = new WiredCaller(address(lister), address(registry));
        vm.prank(admin);
        lister.setFactory(address(wired), true);

        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.InvalidAccount.selector, address(0)));
        wired.list(address(0), true);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.InvalidAccount.selector, stranger));
        wired.list(stranger, true);
        assertFalse(listed.allowedAccounts(stranger));
    }

    function testTheSetupAssertionTiesTheListerToThePublishedRegistryTheFactoryAndTheTellersList() public {
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));

        VedaVaultRegistry other = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        vm.expectRevert(
            abi.encodeWithSelector(VedaTellerLister.RegistryMismatch.selector, address(registry), address(other))
        );
        lister.assertSetup(IVedaVaultRegistry(address(other)), address(factory));

        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.FactoryNotNamed.selector, stranger));
        lister.assertSetup(IVedaVaultRegistry(address(registry)), stranger);

        // Without the Teller permission the setup batch must fail, not the first stack.
        vm.prank(admin);
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller), ITellerAllowlist.setAllowedAccounts.selector, false
        );
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.CannotListOnTeller.selector, address(teller)));
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));

        vm.startPrank(admin);
        _grantListerCapability(teller);
        // A list that is not enforced admits everyone, so listing would decide nothing.
        listed.setAllowlistEnabled(true, false);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.ListNotEnforced.selector, address(teller)));
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowlistEnabled(false, true);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.ListNotEnforced.selector, address(teller)));
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowlistEnabled(true, true);
        // A Queue that applies no list would keep serving a delisted engine.
        AllowlistQueue(address(queue)).setTeller(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(VedaTellerLister.QueueNotBound.selector, address(queue), address(teller))
        );
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        AllowlistQueue(address(queue)).setTeller(address(teller));
        // A stock solver that is not on the list could not redeem a settled request.
        listed.setAllowedAccounts(_one(address(solver)), false);
        vm.expectRevert(
            abi.encodeWithSelector(VedaTellerLister.SolverNotListed.selector, address(solver), address(teller))
        );
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        listed.setAllowedAccounts(_one(address(solver)), true);
        // A list anyone may write admits whoever wants in.
        rolesAuthority.setPublicCapability(address(teller), ITellerAllowlist.setAllowedAccounts.selector, true);
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.ListWritableByAnyone.selector, address(teller)));
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        rolesAuthority.setPublicCapability(address(teller), ITellerAllowlist.setAllowedAccounts.selector, false);
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        vm.stopPrank();

        // Nor does it pass over a Teller that keeps no list.
        AuthedTeller plain = new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
        vm.startPrank(admin);
        _grantTellerVaultRoles(plain);
        _grantListerCapability(plain);
        vm.stopPrank();
        _publish(plain, AuthedQueue(address(0)), AuthedSolver(address(0)));
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.CannotListOnTeller.selector, address(plain)));
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
    }

    function testItsWiringIsFixedAndValidatedAtConstruction() public {
        assertEq(address(lister.registry()), address(registry));
        assertEq(address(factory.tellerLister()), address(lister));

        vm.expectRevert(VedaTellerLister.ZeroAddress.selector);
        new VedaTellerLister(IVedaVaultRegistry(address(0)));
        vm.expectRevert(abi.encodeWithSelector(VedaTellerLister.InvalidListerWiring.selector, stranger));
        new VedaTellerLister(IVedaVaultRegistry(stranger));

        VedaStackFactory.Config memory config = _factoryConfig();
        config.tellerLister = IVedaTellerLister(stranger);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidFactoryWiring.selector, stranger));
        new VedaStackFactory(config);
    }

    function testTheListersRoleReachesNothingButTheTellersList() public {
        _createStack(STACK_A);
        assertEq(rolesAuthority.getUserRoles(address(lister)), bytes32(uint256(1) << LISTER_ROLE));
        assertTrue(_canCall(address(lister), address(teller), ITellerAllowlist.setAllowedAccounts.selector));
        assertFalse(_canCall(address(lister), address(teller), AllowlistTeller.setAllowlistEnabled.selector));
        assertFalse(_canCall(address(lister), address(queue), AllowlistQueue.setTeller.selector));

        bytes4[] memory custody = _custodySelectors();
        for (uint256 i = 0; i < custody.length; i++) {
            assertFalse(_canCall(address(lister), address(vault), custody[i]));
        }
        bytes4[] memory roleAdmin = _roleAdminSelectors();
        for (uint256 i = 0; i < roleAdmin.length; i++) {
            assertFalse(_canCall(address(lister), address(rolesAuthority), roleAdmin[i]));
        }
    }

    // ------------------------------------------------------------------
    // A vault that needs no roles at all
    // ------------------------------------------------------------------

    function testAnImmediateOnlyVaultNeedsNoAuthorizerOnlyTheLister() public {
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));

        VedaTellerLister ownLister = new VedaTellerLister(IVedaVaultRegistry(address(registry)));
        VedaStackFactory.Config memory config = _factoryConfig();
        config.authorizer = IVedaStackAuthorizer(address(0));
        config.tellerLister = IVedaTellerLister(address(ownLister));
        VedaStackFactory listing = new VedaStackFactory(config);
        assertFalse(listing.isAuthorizerBound());

        // The whole setup: one role for the lister, one naming. Nothing writes roles afterwards.
        vm.startPrank(admin);
        rolesAuthority.setUserRole(address(ownLister), LISTER_ROLE, true);
        ownLister.setFactory(address(listing), true);
        ownLister.assertSetup(IVedaVaultRegistry(address(registry)), address(listing));
        vm.stopPrank();
        assertTrue(listing.isAuthorizerBound());

        vm.prank(operator);
        (address engine, address earnVault, address earnShare) =
            listing.createStack(_engineParams(), _coreParams(STACK_A), address(0));
        assertEq(listing.stack(engine).forwarder, address(0));
        assertEq(rolesAuthority.getUserRoles(engine), bytes32(0));
        assertTrue(listed.allowedAccounts(engine));
        assertTrue(listing.isEngineReady(engine));

        assertEq(_deposit(EarnVault(earnVault), user, 50e6), 50e6);
        vm.startPrank(user);
        StackMockShareToken(earnShare).approve(earnVault, 20e6);
        assertEq(EarnVault(earnVault).redeem(20e6, receiver, 20e6), 20e6);
        vm.stopPrank();

        // Revoking is delisting, and it stops the stack.
        vm.prank(admin);
        listing.revokeEngine(engine);
        assertFalse(listed.allowedAccounts(engine));
        _expectDepositRefused(EarnVault(earnVault), "NOT_ALLOWED");
        vm.prank(admin);
        listing.reinstateEngine(engine);
        assertEq(_deposit(EarnVault(earnVault), user, 1e6), 1e6);

        // With the list as the only gate, a revocation the Teller does not take yet is still
        // recorded, so the engine cannot be carried anywhere and anyone can finish the delisting.
        vm.prank(admin);
        rolesAuthority.setUserRole(address(ownLister), LISTER_ROLE, false);
        vm.expectEmit(true, true, false, true, address(listing));
        emit VedaStackFactory.EngineRevocationIncomplete(engine, address(ownLister));
        vm.prank(admin);
        listing.revokeEngine(engine);
        assertEq(uint256(listing.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        assertFalse(ownLister.isListedEngine(engine));
        assertTrue(listed.allowedAccounts(engine));
        vm.prank(admin);
        rolesAuthority.setUserRole(address(ownLister), LISTER_ROLE, true);
        assertEq(ownLister.relist(_one(engine)), 0);
        assertEq(ownLister.redelist(_one(engine)), 1);
        assertFalse(listed.allowedAccounts(engine));
        vm.prank(admin);
        listing.reinstateEngine(engine);
        assertTrue(listed.allowedAccounts(engine));

        // With no authorizer there is nothing to take from a forwarding solver.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.ForwarderNotActive.selector, stranger));
        listing.revokeForwarder(stranger);

        // Once the vault has a Queue, whose callers are gated by role, this factory cannot build a
        // stack that could use it, and says so instead of reporting one.
        _rotate(teller, queue, solver);
        vm.prank(operator);
        vm.expectPartialRevert(VedaStackFactory.NotAuthorizedOnVeda.selector);
        listing.createStack(_engineParams(), _coreParams(STACK_B), address(0));
        assertEq(listing.engineCount(), 1);
    }

    function testAFactoryWithNeitherGateHoldsNoPermissionAndRevokesNothing() public {
        // An immediate-only vault whose list someone else keeps. This factory is named by no one,
        // because it can change nothing on Veda: its records say only that it built a stack.
        _rotate(teller, AuthedQueue(address(0)), AuthedSolver(address(0)));
        VedaStackFactory.Config memory config = _factoryConfig();
        config.authorizer = IVedaStackAuthorizer(address(0));
        config.tellerLister = IVedaTellerLister(address(0));
        VedaStackFactory bare = new VedaStackFactory(config);
        assertTrue(bare.isAuthorizerBound());

        vm.prank(operator);
        vm.expectPartialRevert(VedaStackFactory.NotListedOnTeller.selector);
        bare.createStack(_engineParams(), _coreParams(STACK_A), address(0));

        vm.prank(operator);
        address engine = bare.deployEngine(_engineParams());
        _setListedDirectly(engine, true);
        vm.prank(operator);
        (address earnVault,) = bare.finalizeStack(engine, _coreParams(STACK_A), address(0));
        assertTrue(bare.isEngineReady(engine));
        assertEq(rolesAuthority.getUserRoles(engine), bytes32(0));
        assertEq(_deposit(EarnVault(earnVault), user, 5e6), 5e6);

        // It gave the engine nothing, so it has nothing to take away and does not pretend to.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.RevocationFailed.selector, engine));
        bare.revokeEngine(engine);
        assertEq(uint256(bare.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Active));
        // Whoever keeps the list stops the engine, and readiness follows the Teller.
        _setListedDirectly(engine, false);
        assertFalse(bare.isEngineReady(engine));
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
        (supported,) = probe.queueTeller(address(module));
        assertFalse(supported);
        module.set(Shapeshifter.Shape.Word, uint256(uint160(address(teller))));
        (bool queueChecks, address queueTeller) = probe.queueTeller(address(module));
        assertTrue(queueChecks);
        assertEq(queueTeller, address(teller));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _setListedDirectly(address account, bool allowed) private {
        vm.prank(admin);
        listed.setAllowedAccounts(_one(account), allowed);
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
            IBoringSolver(address(solver)),
            1,
            type(uint256).max,
            MAX_RATE_AGE
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
        (bool queueChecks, address queueTeller) = probe.queueTeller(module);
        assertFalse(queueChecks);
        assertEq(queueTeller, address(0));
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

/// @dev Anyone tries the lister directly: listing an account, carrying one over, revoking a listing.
contract VedaListerHandler is Test {
    VedaTellerLister public immutable lister;
    VedaRoleStackHandler public immutable stacks;
    address[] public actors;

    constructor(VedaTellerLister lister_, VedaRoleStackHandler stacks_, address[] memory actors_) {
        lister = lister_;
        stacks = stacks_;
        actors = actors_;
    }

    function setEngineListed(uint256 actorSeed, uint256 accountSeed, bool listed) external {
        vm.prank(_actor(actorSeed));
        try lister.setEngineListed(_account(accountSeed), listed) { } catch { }
    }

    function relist(uint256 actorSeed, uint256 accountSeed) external {
        address[] memory accounts = new address[](1);
        accounts[0] = _account(accountSeed);
        vm.prank(_actor(actorSeed));
        try lister.relist(accounts) { } catch { }
    }

    function redelist(uint256 actorSeed, uint256 accountSeed) external {
        address[] memory accounts = new address[](1);
        accounts[0] = _account(accountSeed);
        vm.prank(_actor(actorSeed));
        try lister.redelist(accounts) { } catch { }
    }

    function revokeListing(uint256 actorSeed, uint256 accountSeed) external {
        // The administrator's own delisting is left out: it is meant to part the list from the
        // factory's record, which the invariant below holds equal.
        address actor = _actor(actorSeed);
        if (lister.registry().isVaultAdmin(actor)) return;
        vm.prank(actor);
        try lister.revokeListing(_account(accountSeed)) { } catch { }
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
    VedaListerHandler private listerHandler;
    address[] private _actors;
    AllowlistTeller private listed;

    function setUp() public override {
        super.setUp();
        listed = AllowlistTeller(address(teller));
        _actors = [operator, admin, pauser, stranger, stackOwner];
        stacks = new VedaRoleStackHandler(factory, granter, _actors);
        listerHandler = new VedaListerHandler(lister, stacks, _actors);
        targetContract(address(stacks));
        targetContract(address(listerHandler));
    }

    /// @dev The handlers' calls do land for their rightful callers, so the invariant below is checked
    ///      over listed, delisted and relisted engines and not over reverts alone.
    function testHandlerCallsLandForTheirRightfulCallers() public {
        stacks.createStack(0, stackOwner, address(0)); // operator
        address engine = stacks.engines(0);
        assertTrue(listed.allowedAccounts(engine));
        stacks.revokeOrReinstateEngine(2, 0, true); // pauser
        assertFalse(listed.allowedAccounts(engine));
        listerHandler.relist(3, 0); // a stranger cannot bring it back
        assertFalse(listed.allowedAccounts(engine));
        stacks.revokeOrReinstateEngine(1, 0, false); // administrator
        assertTrue(listed.allowedAccounts(engine));
        listerHandler.setEngineListed(3, 0, false); // a stranger cannot delist it
        assertTrue(listed.allowedAccounts(engine));
    }

    /// @dev Whatever anyone calls, the Teller's list holds the stock solver and exactly the engines
    ///      this factory records as active, and the lister's record says the same.
    function invariant_theTellersListIsTheStockSolverAndTheActiveEngines() public view {
        for (uint256 i = 0; i < stacks.engineCount(); i++) {
            address engine = stacks.engines(i);
            bool active = factory.stack(engine).status == VedaStackFactory.EngineStatus.Active;
            assertEq(listed.allowedAccounts(engine), active);
            assertEq(lister.isListedEngine(engine), active);
            assertEq(factory.isEngineReady(engine), active);
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
            address(lister),
            address(queue)
        ];
        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(listed.allowedAccounts(others[i]));
            assertFalse(lister.isListedEngine(others[i]));
        }
        assertTrue(listed.allowedAccounts(address(solver)));

        // The lister holds its one role, which reaches no custody function.
        assertEq(rolesAuthority.getUserRoles(address(lister)), bytes32(uint256(1) << LISTER_ROLE));
        bytes4[] memory custody = _custodySelectors();
        for (uint256 i = 0; i < custody.length; i++) {
            assertFalse(rolesAuthority.doesRoleHaveCapability(LISTER_ROLE, address(vault), custody[i]));
        }
    }
}
// forge-lint: disable-end(multi-contract-file,unsafe-typecast)
