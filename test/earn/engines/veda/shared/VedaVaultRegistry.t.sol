// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// The per-vault registry: who may publish, what a publication must satisfy, and how an unmodified
// `VedaEngine` runs on it: bound through `engine()`, and moved to a later publication only by its owner.
// forge-lint: disable-start(multi-contract-file)
import { Test } from "forge-std/Test.sol";
import { VedaEngine } from "../../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IAccountant } from "../../../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../../../../src/interfaces/external/veda/IVedaPeripheryRegistry.sol";
import { AuthedBoringVault, MockRolesAuthority } from "../../../helpers/VedaAuthMocks.sol";
import {
    MockAccountant,
    MockAsset,
    MockBoringVault,
    MockCore,
    MockQueue,
    MockTeller
} from "../../../helpers/VedaEngineMocks.sol";

/// @dev The mock BoringVault with the authority surface a registry reads: it is its own authority and,
///      like the local fixture vault, admits every call, so any Teller wired to it can mint and burn.
contract PermissiveBoringVault is MockBoringVault {
    constructor(address asset_, uint8 decimals_) MockBoringVault(asset_, decimals_) { }

    function authority() external view returns (address) {
        return address(this);
    }

    function canCall(address, address, bytes4) external pure returns (bool) {
        return true;
    }
}

/// @dev Stands in for a Queue's stock solver where a test never solves through it.
contract MockStockSolver {
    function boringRedeemSolve(bytes calldata, address, bool) external pure { }
}

/// @dev Asks a registry which engine it names, as an engine does before it binds.
contract EngineAsker {
    function ask(VedaVaultRegistry registry) external view returns (address) {
        return registry.engine();
    }
}

/// @dev An authority whose `owner()` does not return one clean address.
contract MalformedOwnerAuthority {
    function owner() external pure returns (uint256, uint256) {
        return (1, 2);
    }
}

contract DirtyOwnerAuthority {
    address private immutable _claimed;

    constructor(address claimed_) {
        _claimed = claimed_;
    }

    fallback() external {
        // The claimed owner with a dirty upper byte: not a well-formed address.
        uint256 word = uint256(uint160(_claimed)) | (uint256(1) << 200);
        assembly ("memory-safe") {
            mstore(0, word)
            return(0, 0x20)
        }
    }
}

/// @dev This test owns the mock BoringVault, which is its own authority, so it is the vault's
///      administrator and publishes directly.
contract VedaVaultRegistryTest is Test {
    uint64 internal constant MAX_RATE_AGE = 1 days;

    address internal stranger = makeAddr("stranger");
    MockAsset internal asset;
    MockBoringVault internal vault;
    MockAccountant internal accountant;
    MockTeller internal teller;
    MockQueue internal queue;
    address internal stockSolver;
    VedaVaultRegistry internal registry;

    event VedaVaultPeripheryPublished(
        uint64 indexed version, address indexed teller, address indexed queue, address accountant, address solver
    );

    function setUp() public {
        asset = new MockAsset();
        vault = new PermissiveBoringVault(address(asset), 6);
        accountant = new MockAccountant(vault, address(asset));
        teller = new MockTeller(vault, accountant, address(asset));
        queue = new MockQueue(vault, accountant);
        stockSolver = address(new MockStockSolver());
        registry = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        _publish(teller, queue, accountant);
    }

    // ------------------------------------------------------------------
    // Publication
    // ------------------------------------------------------------------

    function testPublishStoresTheTupleAndCountsTheVersion() public {
        assertEq(address(registry.vault()), address(vault));
        assertEq(registry.baseAsset(), address(asset));
        assertEq(registry.version(), 1);
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);

        vm.expectEmit(true, true, true, true, address(registry));
        emit VedaVaultPeripheryPublished(2, address(newTeller), address(newQueue), address(newAccountant), stockSolver);
        _publish(newTeller, newQueue, newAccountant);

        assertEq(address(registry.teller()), address(newTeller));
        assertEq(address(registry.queue()), address(newQueue));
        assertEq(address(registry.accountant()), address(newAccountant));
        assertEq(address(registry.solver()), stockSolver);
        assertEq(registry.version(), 2);
    }

    function testEveryModuleMustBeWiredToThisVaultAndToEachOther() public {
        MockAsset otherAsset = new MockAsset();
        MockBoringVault otherVault = new MockBoringVault(address(otherAsset), 6);
        MockAccountant otherAccountant = new MockAccountant(vault, address(asset));
        MockAccountant wrongBase = new MockAccountant(vault, address(otherAsset));
        MockAccountant wrongVaultAccountant = new MockAccountant(otherVault, address(asset));

        // Teller on another vault, then on another Accountant.
        MockTeller wrongVaultTeller = new MockTeller(otherVault, accountant, address(asset));
        _expectWiring(address(wrongVaultTeller), address(vault), address(otherVault));
        _publish(wrongVaultTeller, queue, accountant);
        MockTeller wrongAccountantTeller = new MockTeller(vault, otherAccountant, address(asset));
        _expectWiring(address(wrongAccountantTeller), address(accountant), address(otherAccountant));
        _publish(wrongAccountantTeller, queue, accountant);

        // Queue on another vault, then on another Accountant.
        MockQueue wrongVaultQueue = new MockQueue(otherVault, accountant);
        _expectWiring(address(wrongVaultQueue), address(vault), address(otherVault));
        _publish(teller, wrongVaultQueue, accountant);
        MockQueue wrongAccountantQueue = new MockQueue(vault, otherAccountant);
        _expectWiring(address(wrongAccountantQueue), address(accountant), address(otherAccountant));
        _publish(teller, wrongAccountantQueue, accountant);

        // Accountant for another vault, then pricing another asset.
        MockTeller tellerForWrongVault = new MockTeller(vault, wrongVaultAccountant, address(asset));
        _expectWiring(address(wrongVaultAccountant), address(vault), address(otherVault));
        _publish(tellerForWrongVault, MockQueue(address(0)), wrongVaultAccountant);
        MockTeller tellerForWrongBase = new MockTeller(vault, wrongBase, address(asset));
        _expectWiring(address(wrongBase), address(asset), address(otherAsset));
        _publish(tellerForWrongBase, MockQueue(address(0)), wrongBase);

        assertEq(registry.version(), 1);
    }

    function testModulesMustBeContracts() public {
        address codeless = makeAddr("codeless");
        vm.expectRevert(VedaVaultRegistry.ZeroAddress.selector);
        _publishRaw(address(0), address(queue), address(accountant), stockSolver);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, codeless));
        _publishRaw(codeless, address(queue), address(accountant), stockSolver);
        vm.expectRevert(VedaVaultRegistry.ZeroAddress.selector);
        _publishRaw(address(teller), address(queue), address(0), stockSolver);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, codeless));
        _publishRaw(address(teller), address(queue), codeless, stockSolver);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, codeless));
        _publishRaw(address(teller), codeless, address(accountant), stockSolver);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, codeless));
        _publishRaw(address(teller), address(queue), address(accountant), codeless);

        vm.expectRevert(VedaVaultRegistry.ZeroAddress.selector);
        new VedaVaultRegistry(IBoringVault(address(0)), address(asset));
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, codeless));
        new VedaVaultRegistry(IBoringVault(address(vault)), codeless);
    }

    function testAQueueAndItsStockSolverArePublishedTogetherOrNotAtAll() public {
        // A Queue nothing can settle would strand every queued exit.
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.QueueSolverMismatch.selector, address(queue), address(0))
        );
        _publishRaw(address(teller), address(queue), address(accountant), address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.QueueSolverMismatch.selector, address(0), stockSolver));
        _publishRaw(address(teller), address(0), address(accountant), stockSolver);

        // Immediate-only: neither.
        _publishRaw(address(teller), address(0), address(accountant), address(0));
        assertEq(address(registry.queue()), address(0));
        assertEq(address(registry.solver()), address(0));
        assertEq(registry.version(), 2);
    }

    function testAQueueWithoutOnchainTrackingIsRefused() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        newQueue.setTrackWithdrawsOnChain(false);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.QueueTrackingDisabled.selector, address(newQueue)));
        _publish(newTeller, newQueue, newAccountant);
    }

    function testATellerThatCannotMintAndBurnTheVaultsSharesIsRefused() public {
        // An engine does not check this before it activates a tuple, and one that activated such a
        // Teller could neither deposit nor exit.
        address timelock = makeAddr("timelock");
        MockRolesAuthority rolesAuthority = new MockRolesAuthority(timelock, address(0));
        AuthedBoringVault authedVault = new AuthedBoringVault(address(0), address(rolesAuthority), 6);
        MockAccountant authedAccountant = new MockAccountant(MockBoringVault(address(authedVault)), address(asset));
        MockTeller authedTeller =
            new MockTeller(MockBoringVault(address(authedVault)), authedAccountant, address(asset));
        VedaVaultRegistry authedRegistry = new VedaVaultRegistry(IBoringVault(address(authedVault)), address(asset));
        bytes4 enter = authedVault.enter.selector;
        bytes4 exit = authedVault.exit.selector;

        vm.startPrank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.TellerNotAuthorizedOnVault.selector, address(authedTeller), enter)
        );
        _publishTo(authedRegistry, address(authedTeller), address(authedAccountant));

        // The minter role alone is not enough: every immediate exit burns through the Teller.
        rolesAuthority.setRoleCapability(2, address(authedVault), enter, true);
        rolesAuthority.setUserRole(address(authedTeller), 2, true);
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.TellerNotAuthorizedOnVault.selector, address(authedTeller), exit)
        );
        _publishTo(authedRegistry, address(authedTeller), address(authedAccountant));

        rolesAuthority.setRoleCapability(3, address(authedVault), exit, true);
        rolesAuthority.setUserRole(address(authedTeller), 3, true);
        _publishTo(authedRegistry, address(authedTeller), address(authedAccountant));
        vm.stopPrank();
        assertEq(address(authedRegistry.teller()), address(authedTeller));
    }

    function testATellerOnAVaultWithoutAnAuthorityMustBeItsOwner() public {
        MockBoringVault bareVault = new MockBoringVault(address(asset), 6);
        MockAccountant bareAccountant = new MockAccountant(bareVault, address(asset));
        MockTeller bareTeller = new MockTeller(bareVault, bareAccountant, address(asset));
        VedaVaultRegistry bareRegistry = new VedaVaultRegistry(IBoringVault(address(bareVault)), address(asset));

        vm.expectRevert(
            abi.encodeWithSelector(
                VedaVaultRegistry.TellerNotAuthorizedOnVault.selector,
                address(bareTeller),
                bytes4(keccak256("enter(address,address,uint256,address,uint256)"))
            )
        );
        _publishTo(bareRegistry, address(bareTeller), address(bareAccountant));

        // An owner passes every gated call on the vault, so an owning Teller reaches it. The vault's new
        // owner is the Teller, so it is also the one that publishes.
        bareVault.transferOwnership(address(bareTeller));
        vm.prank(address(bareTeller));
        _publishTo(bareRegistry, address(bareTeller), address(bareAccountant));
        assertEq(address(bareRegistry.teller()), address(bareTeller));
    }

    function testTheStockSolverIsNoneOfTheContractsAlreadyNamed() public {
        // The solver exposes no wiring to check, so a slip that names another module there is caught.
        address[5] memory named =
            [address(vault), address(teller), address(queue), address(accountant), address(registry)];
        for (uint256 i = 0; i < named.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeriphery.selector, named[i]));
            _publishRaw(address(teller), address(queue), address(accountant), named[i]);
        }
    }

    // ------------------------------------------------------------------
    // The engines it serves
    // ------------------------------------------------------------------

    function testItNamesEveryCallerAsItsEngineSoAnUnmodifiedEngineBinds() public {
        // A `VedaEngine` binds only when its registry names it. This registry picks no engine: it
        // answers each caller with the caller's own address.
        EngineAsker first = new EngineAsker();
        EngineAsker second = new EngineAsker();
        assertEq(first.ask(registry), address(first));
        assertEq(second.ask(registry), address(second));
        vm.prank(stranger);
        assertEq(registry.engine(), stranger);

        // So any number of released engines bind on the one registry, each to its own EarnVault.
        (VedaEngine engineA, MockCore coreA) = _bindEngine();
        (VedaEngine engineB, MockCore coreB) = _bindEngine();
        assertEq(address(engineA.peripheryRegistry()), address(registry));
        assertEq(engineA.earnVault(), address(coreA));
        assertEq(engineB.earnVault(), address(coreB));
        assertEq(address(engineA.teller()), address(teller));
        assertEq(address(engineA.queue()), address(queue));
        assertEq(address(engineA.accountant()), address(accountant));
        assertEq(engineA.peripheryVersion(), 1);

        asset.mint(address(coreA), 10e6);
        assertEq(coreA.deposit(10e6), 10e6);
        assertEq(vault.balanceOf(address(engineA)), 10e6);
        assertEq(vault.balanceOf(address(engineB)), 0);
    }

    function testAPublicationMovesNoEngineUntilItsOwnerActivatesIt() public {
        (VedaEngine engineA, MockCore coreA) = _bindEngine();
        (VedaEngine engineB,) = _bindEngine();
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);
        _publish(newTeller, newQueue, newAccountant);

        // Both engines keep the tuple they were built on.
        assertEq(address(engineA.teller()), address(teller));
        assertEq(address(engineB.teller()), address(teller));
        assertEq(engineA.peripheryVersion(), 1);

        // Activation is the engine's own: its owner, with deposits paused, inside its rate bounds.
        vm.prank(stranger);
        vm.expectRevert();
        engineA.syncVedaPeriphery(1, type(uint256).max);
        vm.expectRevert(VedaEngine.DepositsNotPaused.selector);
        engineA.syncVedaPeriphery(1, type(uint256).max);
        coreA.setDepositsPaused(true);
        vm.expectRevert(abi.encodeWithSelector(VedaEngine.VedaRateOutOfBounds.selector, 2e6, 1e6, 1_500_000));
        engineA.syncVedaPeriphery(1e6, 1_500_000);
        engineA.syncVedaPeriphery(2e6, 2e6);

        assertEq(address(engineA.teller()), address(newTeller));
        assertEq(address(engineA.queue()), address(newQueue));
        assertEq(address(engineA.accountant()), address(newAccountant));
        assertEq(engineA.peripheryVersion(), 2);
        // The other engine is untouched.
        assertEq(address(engineB.teller()), address(teller));
        assertEq(engineB.peripheryVersion(), 1);
    }

    function testAnEngineIsBuiltOnlyOnARegistryThatHasPublished() public {
        VedaVaultRegistry empty = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        vm.expectRevert(VedaEngine.NoPublishedVedaPeriphery.selector);
        new VedaEngine(IVedaPeripheryRegistry(address(empty)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT");
    }

    // ------------------------------------------------------------------
    // Who administers a vault
    // ------------------------------------------------------------------

    function testAVaultWithoutAnAuthorityIsAdministeredByItsOwnerAlone() public {
        // A bare mock BoringVault has an owner and no authority at all.
        MockBoringVault bareVault = new MockBoringVault(address(asset), 6);
        VedaVaultRegistry bareRegistry = new VedaVaultRegistry(IBoringVault(address(bareVault)), address(asset));
        assertTrue(bareRegistry.isVaultAdmin(address(this)));
        assertFalse(bareRegistry.isVaultAdmin(stranger));
        assertFalse(bareRegistry.isVaultAdmin(address(0)));
        bareVault.transferOwnership(stranger);
        assertFalse(bareRegistry.isVaultAdmin(address(this)));
        assertTrue(bareRegistry.isVaultAdmin(stranger));

        // The fixture vault is its own authority, so its owner administers it either way.
        assertTrue(registry.isVaultAdmin(address(this)));
        assertFalse(registry.isVaultAdmin(stranger));
        assertFalse(registry.isVaultAdmin(address(0)));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.NotVaultAdmin.selector, stranger));
        registry.publish(
            ITeller(address(teller)),
            IBoringQueue(address(queue)),
            IAccountant(address(accountant)),
            IBoringSolver(stockSolver)
        );

        vault.transferOwnership(stranger);
        assertFalse(registry.isVaultAdmin(address(this)));
        assertTrue(registry.isVaultAdmin(stranger));
    }

    function testAFinalizedVaultIsAdministeredByTheOwnerOfItsRolesAuthority() public {
        address timelock = makeAddr("timelock");
        address roleHolder = makeAddr("role holder");
        MockRolesAuthority rolesAuthority = new MockRolesAuthority(timelock, address(0));
        AuthedBoringVault finalized = new AuthedBoringVault(address(0), address(rolesAuthority), 6);
        VedaVaultRegistry finalizedRegistry = new VedaVaultRegistry(IBoringVault(address(finalized)), address(asset));
        // A role, however strong, is not administration of the registry.
        vm.startPrank(timelock);
        rolesAuthority.setUserRole(roleHolder, 8, true);
        rolesAuthority.setRoleCapability(8, address(finalizedRegistry), VedaVaultRegistry.publish.selector, true);
        rolesAuthority.setPublicCapability(address(finalizedRegistry), VedaVaultRegistry.publish.selector, true);
        vm.stopPrank();

        assertTrue(finalizedRegistry.isVaultAdmin(timelock));
        assertFalse(finalizedRegistry.isVaultAdmin(roleHolder));
        assertFalse(finalizedRegistry.isVaultAdmin(stranger));
        // The vault has no owner, and the zero address is never an administrator.
        assertEq(finalized.owner(), address(0));
        assertFalse(finalizedRegistry.isVaultAdmin(address(0)));

        // The administrator is read live: it follows the RolesAuthority's owner...
        address successor = makeAddr("successor");
        vm.prank(timelock);
        rolesAuthority.transferOwnership(successor);
        assertFalse(finalizedRegistry.isVaultAdmin(timelock));
        assertTrue(finalizedRegistry.isVaultAdmin(successor));

        // ...and the vault's authority pointer, never a RolesAuthority the vault has left.
        MockRolesAuthority replacement = new MockRolesAuthority(timelock, address(0));
        vm.prank(successor);
        rolesAuthority.setUserRole(successor, 8, true);
        vm.prank(successor);
        rolesAuthority.setRoleCapability(8, address(finalized), finalized.setAuthority.selector, true);
        vm.prank(successor);
        finalized.setAuthority(address(replacement));
        assertFalse(finalizedRegistry.isVaultAdmin(successor));
        assertTrue(finalizedRegistry.isVaultAdmin(timelock));
    }

    function testAnAuthorityWithoutAWellFormedOwnerContributesNoAdministrator() public {
        address claimed = makeAddr("claimed owner");
        address[4] memory authorities = [
            address(0),
            makeAddr("authority without code"),
            address(new MalformedOwnerAuthority()),
            address(new DirtyOwnerAuthority(claimed))
        ];
        for (uint256 i = 0; i < authorities.length; i++) {
            AuthedBoringVault authedVault = new AuthedBoringVault(address(this), authorities[i], 6);
            VedaVaultRegistry authedRegistry = new VedaVaultRegistry(IBoringVault(address(authedVault)), address(asset));
            assertTrue(authedRegistry.isVaultAdmin(address(this)));
            assertFalse(authedRegistry.isVaultAdmin(claimed));
            assertFalse(authedRegistry.isVaultAdmin(stranger));
            assertFalse(authedRegistry.isVaultAdmin(address(0)));
            assertFalse(authedRegistry.isVaultAdmin(authorities[i]));
        }
    }

    function _newPeriphery(uint256 rate_)
        private
        returns (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue)
    {
        newAccountant = new MockAccountant(vault, address(asset));
        newAccountant.setRate(rate_);
        newTeller = new MockTeller(vault, newAccountant, address(asset));
        newQueue = new MockQueue(vault, newAccountant);
    }

    /// @dev A released engine on the shared registry, owned by this test and bound to a fresh core.
    function _bindEngine() private returns (VedaEngine engine, MockCore core) {
        engine = new VedaEngine(
            IVedaPeripheryRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
        core = new MockCore(asset);
        core.setEngine(engine);
        engine.initializeEarnVault(address(core));
    }

    /// @dev A zero Queue publishes no stock solver.
    function _publish(MockTeller newTeller, MockQueue newQueue, MockAccountant newAccountant) private {
        registry.publish(
            ITeller(address(newTeller)),
            IBoringQueue(address(newQueue)),
            IAccountant(address(newAccountant)),
            IBoringSolver(address(newQueue) == address(0) ? address(0) : stockSolver)
        );
    }

    function _publishTo(VedaVaultRegistry registry_, address teller_, address accountant_) private {
        registry_.publish(
            ITeller(teller_), IBoringQueue(address(0)), IAccountant(accountant_), IBoringSolver(address(0))
        );
    }

    function _expectWiring(address component, address expected, address actual) private {
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeripheryWiring.selector, component, expected, actual)
        );
    }

    function _publishRaw(address teller_, address queue_, address accountant_, address solver_) private {
        registry.publish(ITeller(teller_), IBoringQueue(queue_), IAccountant(accountant_), IBoringSolver(solver_));
    }
}
// forge-lint: disable-end(multi-contract-file)
