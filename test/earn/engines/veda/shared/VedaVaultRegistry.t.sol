// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// The per-vault registry: who may publish, and what a publication must satisfy now that no engine
// re-checks a tuple before using it.
// forge-lint: disable-start(multi-contract-file)
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IAccountant } from "../../../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import { AuthedBoringVault, MockRolesAuthority } from "../../../helpers/VedaAuthMocks.sol";
import {
    MockAccountant,
    MockAsset,
    MockBoringVault,
    MockQueue,
    MockTeller
} from "../../../helpers/VedaEngineMocks.sol";
import { VedaLockstepEngineTestBase } from "../../../helpers/VedaLockstepEngineTestBase.sol";

/// @dev Step-accounting Accountant: its report time is the eighth word of `accountantState()`.
contract StepAccountant {
    address public immutable vault;
    address public immutable base;
    uint64 public lastUpdate;
    uint256 public stateWords = 12;

    constructor(address vault_, address base_) {
        vault = vault_;
        base = base_;
        lastUpdate = uint64(block.timestamp);
    }

    function setLastUpdate(uint64 lastUpdate_) external {
        lastUpdate = lastUpdate_;
    }

    function setStateWords(uint256 stateWords_) external {
        stateWords = stateWords_;
    }

    function getRate() external pure returns (uint256) {
        return 1e6;
    }

    function getRateInQuoteSafe(address) external pure returns (uint256) {
        return 1e6;
    }

    function accountantState() external view returns (bytes memory) {
        uint256 words = stateWords;
        uint256 updatedAt = lastUpdate;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, calldatasize(), mul(words, 0x20))
            mstore(add(ptr, 0xe0), updatedAt)
            return(ptr, mul(words, 0x20))
        }
    }
}

/// @dev A step-accounting tuple of the right length whose `dirtyField` holds a value outside its type.
contract DirtyStepAccountant {
    address public immutable vault;
    address public immutable base;
    uint256 private immutable _dirtyField;

    constructor(address vault_, address base_, uint256 dirtyField_) {
        vault = vault_;
        base = base_;
        _dirtyField = dirtyField_;
    }

    function getRateInQuoteSafe(address) external pure returns (uint256) {
        return 1e6;
    }

    function accountantState() external view returns (bytes memory) {
        uint256 dirtyField = _dirtyField;
        uint256 updatedAt = block.timestamp;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, calldatasize(), 0x180)
            mstore(add(ptr, 0xe0), updatedAt)
            // The top bit is outside every field's type, the timestamp's included.
            mstore(add(ptr, mul(dirtyField, 0x20)), or(mload(add(ptr, mul(dirtyField, 0x20))), shl(255, 1)))
            return(ptr, 0x180)
        }
    }
}

/// @dev A step-accounting Accountant that answers `accountantState()` with exactly the words it is given.
contract ShapedStepAccountant {
    address public immutable vault;
    address public immutable base;
    uint256[12] public words;

    constructor(address vault_, address base_) {
        vault = vault_;
        base = base_;
    }

    function setWord(uint256 index, uint256 word) external {
        words[index] = word;
    }

    function getRateInQuoteSafe(address) external pure returns (uint256) {
        return 1e6;
    }

    function accountantState() external view returns (uint256[12] memory) {
        return words;
    }
}

/// @dev An Accountant with no report-age surface at all.
contract OpaqueAccountant {
    address public immutable vault;
    address public immutable base;

    constructor(address vault_, address base_) {
        vault = vault_;
        base = base_;
    }

    function getRateInQuoteSafe(address) external pure returns (uint256) {
        return 1e6;
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

contract VedaVaultRegistryTest is VedaLockstepEngineTestBase {
    address internal stranger = makeAddr("stranger");

    event VedaVaultPeripheryPublished(
        uint64 indexed version,
        address indexed teller,
        address indexed queue,
        address accountant,
        address solver,
        uint256 validatedRate
    );

    // ------------------------------------------------------------------
    // Publication
    // ------------------------------------------------------------------

    function testPublishStoresTheTupleCountsTheVersionAndReportsTheValidatedRate() public {
        assertEq(address(registry.vault()), address(vault));
        assertEq(registry.baseAsset(), address(asset));
        assertEq(registry.version(), 1);
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);

        vm.expectEmit(true, true, true, true, address(registry));
        emit VedaVaultPeripheryPublished(
            2, address(newTeller), address(newQueue), address(newAccountant), stockSolver, 2e6
        );
        _publish(newTeller, newQueue, newAccountant, 2e6, 2e6);

        assertEq(address(registry.teller()), address(newTeller));
        assertEq(address(registry.queue()), address(newQueue));
        assertEq(address(registry.accountant()), address(newAccountant));
        assertEq(address(registry.solver()), stockSolver);
        assertEq(registry.version(), 2);
    }

    function testAPublicationOutsideTheCallersRateBoundsIsRefused() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);

        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.VedaRateOutOfBounds.selector, 2e6, 1e6, 1_500_000));
        _publish(newTeller, newQueue, newAccountant, 1e6, 1_500_000);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.VedaRateOutOfBounds.selector, 2e6, 2e6 + 1, 3e6));
        _publish(newTeller, newQueue, newAccountant, 2e6 + 1, 3e6);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaRateBounds.selector, 0, 3e6));
        _publish(newTeller, newQueue, newAccountant, 0, 3e6);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaRateBounds.selector, 3e6, 2e6));
        _publish(newTeller, newQueue, newAccountant, 3e6, 2e6);

        assertEq(address(registry.accountant()), address(accountant));
        assertEq(registry.version(), 1);
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
        _publish(wrongVaultTeller, queue, accountant, 1, type(uint256).max);
        MockTeller wrongAccountantTeller = new MockTeller(vault, otherAccountant, address(asset));
        _expectWiring(address(wrongAccountantTeller), address(accountant), address(otherAccountant));
        _publish(wrongAccountantTeller, queue, accountant, 1, type(uint256).max);

        // Queue on another vault, then on another Accountant.
        MockQueue wrongVaultQueue = new MockQueue(otherVault, accountant);
        _expectWiring(address(wrongVaultQueue), address(vault), address(otherVault));
        _publish(teller, wrongVaultQueue, accountant, 1, type(uint256).max);
        MockQueue wrongAccountantQueue = new MockQueue(vault, otherAccountant);
        _expectWiring(address(wrongAccountantQueue), address(accountant), address(otherAccountant));
        _publish(teller, wrongAccountantQueue, accountant, 1, type(uint256).max);

        // Accountant for another vault, then pricing another asset.
        MockTeller tellerForWrongVault = new MockTeller(vault, wrongVaultAccountant, address(asset));
        _expectWiring(address(wrongVaultAccountant), address(vault), address(otherVault));
        _publish(tellerForWrongVault, MockQueue(address(0)), wrongVaultAccountant, 1, type(uint256).max);
        MockTeller tellerForWrongBase = new MockTeller(vault, wrongBase, address(asset));
        _expectWiring(address(wrongBase), address(asset), address(otherAsset));
        _publish(tellerForWrongBase, MockQueue(address(0)), wrongBase, 1, type(uint256).max);

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
        _publish(newTeller, newQueue, newAccountant, 1, type(uint256).max);
    }

    function testAnAccountantWhoseReportAgeCannotBeReadOrIsNotSaneIsRefused() public {
        // Every engine reads the report age before a deposit, so an unreadable one would stop them all.
        OpaqueAccountant opaque = new OpaqueAccountant(address(vault), address(asset));
        MockTeller opaqueTeller = new MockTeller(vault, MockAccountant(address(opaque)), address(asset));
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.UnsupportedAccountantFreshness.selector, address(opaque))
        );
        _publishRaw(address(opaqueTeller), address(0), address(opaque), address(0));

        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        newAccountant.setLastStrategistUpdateTimestamp(0);
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidRateTimestamp.selector, 0, block.timestamp));
        _publish(newTeller, newQueue, newAccountant, 1, type(uint256).max);

        newAccountant.setLastStrategistUpdateTimestamp(uint64(block.timestamp + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaVaultRegistry.InvalidRateTimestamp.selector, block.timestamp + 1, block.timestamp
            )
        );
        _publish(newTeller, newQueue, newAccountant, 1, type(uint256).max);
    }

    function testAStepAccountingAccountantIsAcceptedThroughItsStateTuple() public {
        StepAccountant step = new StepAccountant(address(vault), address(asset));
        MockTeller stepTeller = new MockTeller(vault, MockAccountant(address(step)), address(asset));
        _publishRaw(address(stepTeller), address(0), address(step), address(0));
        assertEq(address(registry.accountant()), address(step));

        // A tuple of another shape is not that Accountant.
        StepAccountant truncated = new StepAccountant(address(vault), address(asset));
        truncated.setStateWords(11);
        MockTeller truncatedTeller = new MockTeller(vault, MockAccountant(address(truncated)), address(asset));
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.UnsupportedAccountantFreshness.selector, address(truncated))
        );
        _publishRaw(address(truncatedTeller), address(0), address(truncated), address(0));

        StepAccountant unreported = new StepAccountant(address(vault), address(asset));
        unreported.setLastUpdate(0);
        MockTeller unreportedTeller = new MockTeller(vault, MockAccountant(address(unreported)), address(asset));
        vm.expectRevert(abi.encodeWithSelector(VedaVaultRegistry.InvalidRateTimestamp.selector, 0, block.timestamp));
        _publishRaw(address(unreportedTeller), address(0), address(unreported), address(0));
    }

    function testAReportOlderThanTheCallerAllowsIsRefused() public {
        // Every engine would refuse deposits against it, so the publication is refused instead.
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        uint64 reportedAt = newAccountant.lastStrategistUpdateTimestamp();
        vm.warp(uint256(reportedAt) + 2 hours + 1);

        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.StaleAccountantRate.selector, reportedAt, block.timestamp, 2 hours)
        );
        _publishAged(newTeller, newQueue, newAccountant, 2 hours);
        vm.expectRevert(VedaVaultRegistry.InvalidMaxReportAge.selector);
        _publishAged(newTeller, newQueue, newAccountant, 0);

        _publishAged(newTeller, newQueue, newAccountant, 2 hours + 1);
        assertEq(address(registry.accountant()), address(newAccountant));
    }

    function testATellerThatCannotMintAndBurnTheVaultsSharesIsRefused() public {
        // One such Teller would stop every stack's deposits and exits in the same block.
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

    function testAStateTupleWithAMalformedFieldIsNotAStepAccountant() public {
        // Any field outside its type's range fails a typed decode of the tuple, so it is refused here too.
        for (uint256 field = 0; field < 12; field++) {
            DirtyStepAccountant dirty = new DirtyStepAccountant(address(vault), address(asset), field);
            MockTeller dirtyTeller = new MockTeller(vault, MockAccountant(address(dirty)), address(asset));
            vm.expectRevert(
                abi.encodeWithSelector(VedaVaultRegistry.UnsupportedAccountantFreshness.selector, address(dirty))
            );
            _publishRaw(address(dirtyTeller), address(0), address(dirty), address(0));
        }
    }

    function testEveryStateFieldIsAcceptedUpToItsTypesMaximumAndNoFurther() public {
        // AccountantState, field for field. A table one bit too narrow would refuse a real Accountant,
        // and one bit too wide would accept a tuple a typed decode rejects.
        uint8[12] memory fieldBits = [160, 96, 128, 128, 96, 16, 16, 64, 1, 24, 16, 16];
        uint256 timestampField = 7;
        ShapedStepAccountant shaped = new ShapedStepAccountant(address(vault), address(asset));
        MockTeller shapedTeller = new MockTeller(vault, MockAccountant(address(shaped)), address(asset));
        for (uint256 i = 0; i < 12; i++) {
            shaped.setWord(i, i == timestampField ? block.timestamp : (uint256(1) << fieldBits[i]) - 1);
        }
        _publishRaw(address(shapedTeller), address(0), address(shaped), address(0));
        assertEq(address(registry.accountant()), address(shaped));

        // The timestamp at its own maximum is still a well-formed tuple: refused as a future report,
        // not as an unreadable one.
        shaped.setWord(timestampField, type(uint64).max);
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.InvalidRateTimestamp.selector, type(uint64).max, block.timestamp)
        );
        _publishRaw(address(shapedTeller), address(0), address(shaped), address(0));
        shaped.setWord(timestampField, block.timestamp);

        // One bit beyond any field's type is not.
        for (uint256 i = 0; i < 12; i++) {
            uint256 wellFormed = shaped.words(i);
            shaped.setWord(i, uint256(1) << fieldBits[i]);
            vm.expectRevert(
                abi.encodeWithSelector(VedaVaultRegistry.UnsupportedAccountantFreshness.selector, address(shaped))
            );
            _publishRaw(address(shapedTeller), address(0), address(shaped), address(0));
            shaped.setWord(i, wellFormed);
        }
        _publishRaw(address(shapedTeller), address(0), address(shaped), address(0));
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
            IBoringSolver(stockSolver),
            1,
            type(uint256).max,
            MAX_RATE_AGE
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

    function _publishAged(MockTeller teller_, MockQueue queue_, MockAccountant accountant_, uint64 maxReportAge)
        private
    {
        registry.publish(
            ITeller(address(teller_)),
            IBoringQueue(address(queue_)),
            IAccountant(address(accountant_)),
            IBoringSolver(stockSolver),
            1,
            type(uint256).max,
            maxReportAge
        );
    }

    function _publishTo(VedaVaultRegistry registry_, address teller_, address accountant_) private {
        registry_.publish(
            ITeller(teller_),
            IBoringQueue(address(0)),
            IAccountant(accountant_),
            IBoringSolver(address(0)),
            1,
            type(uint256).max,
            MAX_RATE_AGE
        );
    }

    function _expectWiring(address component, address expected, address actual) private {
        vm.expectRevert(
            abi.encodeWithSelector(VedaVaultRegistry.InvalidVedaPeripheryWiring.selector, component, expected, actual)
        );
    }

    function _publishRaw(address teller_, address queue_, address accountant_, address solver_) private {
        registry.publish(
            ITeller(teller_),
            IBoringQueue(queue_),
            IAccountant(accountant_),
            IBoringSolver(solver_),
            1,
            type(uint256).max,
            MAX_RATE_AGE
        );
    }
}
// forge-lint: disable-end(multi-contract-file)
