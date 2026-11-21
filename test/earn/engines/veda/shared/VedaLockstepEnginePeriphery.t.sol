// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// What differs from `VedaEngine`: the engine reads the vault's registry on every call, so a publication
// reaches every engine at once and the engine owner has no part in it. These tests cover that, and what
// still holds when a published module misbehaves.
// forge-lint: disable-start(multi-contract-file,erc20-unchecked-transfer)
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { VedaEngine } from "../../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaLockstepEngine } from "../../../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IEarnEngineAsyncRedeem } from "../../../../../src/interfaces/earn/engines/IEarnEngineAsyncRedeem.sol";
import { IVedaVaultRegistry } from "../../../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAccountant } from "../../../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import { OnChainWithdraw } from "../../../../../src/interfaces/external/veda/VedaTypes.sol";
import {
    MockAccountant,
    MockAsset,
    MockBoringVault,
    MockCore,
    MockQueue,
    MockTeller
} from "../../../helpers/VedaEngineMocks.sol";
import { VedaLockstepEngineTestBase } from "../../../helpers/VedaLockstepEngineTestBase.sol";

/// @dev An Accountant whose report-age surface can stop answering after it was published.
contract FragileAccountant is MockAccountant {
    bool public broken;

    constructor(MockBoringVault vault_, address base_) MockAccountant(vault_, base_) { }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function lastStrategistUpdateTimestamp() external view override returns (uint64) {
        require(!broken, "NO_REPORT_AGE");
        return _lastStrategistUpdateTimestamp;
    }
}

/// @dev A correctly wired Teller that tries to take the engine's assets and shares for `thief` instead
///      of routing them through the vault.
contract ThievingTeller {
    MockBoringVault public immutable vault;
    MockAccountant public immutable accountant;
    address public immutable thief;
    bool public mintWithoutPulling;

    constructor(MockBoringVault vault_, MockAccountant accountant_, address thief_) {
        vault = vault_;
        accountant = accountant_;
        thief = thief_;
    }

    function setMintWithoutPulling(bool mintWithoutPulling_) external {
        mintWithoutPulling = mintWithoutPulling_;
    }

    function bulkDeposit(address depositAsset, uint256 depositAmount, uint256, address to) external returns (uint256) {
        if (mintWithoutPulling) {
            vault.mint(to, depositAmount);
            return depositAmount;
        }
        // The engine approved the vault, never this Teller.
        MockAsset(depositAsset).transferFrom(msg.sender, thief, depositAmount);
        return depositAmount;
    }

    function bulkWithdraw(address, uint256 shareAmount, uint256, address) external returns (uint256) {
        vault.transferFrom(msg.sender, thief, shareAmount);
        return shareAmount;
    }
}

/// @dev A tracking Queue that pulls the engine's whole allowance, one unit more than the request.
contract GreedyQueue {
    MockBoringVault public immutable boringVault;
    MockAccountant public immutable accountant;
    bool public constant trackWithdrawsOnChain = true;
    mapping(bytes32 => OnChainWithdraw) internal _requests;

    constructor(MockBoringVault vault_, MockAccountant accountant_) {
        boringVault = vault_;
        accountant = accountant_;
    }

    function requestOnChainWithdraw(address assetOut, uint128 shares, uint16, uint24 secondsToDeadline)
        external
        returns (bytes32 requestId)
    {
        boringVault.transferFrom(msg.sender, address(this), boringVault.allowance(msg.sender, address(this)));
        OnChainWithdraw memory request = OnChainWithdraw({
            nonce: 1,
            user: msg.sender,
            assetOut: assetOut,
            amountOfShares: shares,
            amountOfAssets: shares,
            creationTime: uint40(block.timestamp),
            secondsToMaturity: 0,
            secondsToDeadline: secondsToDeadline
        });
        requestId = keccak256(abi.encode(request));
        _requests[requestId] = request;
    }

    function getOnChainWithdraw(bytes32 requestId) external view returns (OnChainWithdraw memory) {
        return _requests[requestId];
    }

    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }
}

/// @dev The vault's administrator acting within one transaction: an engine operation, a publication,
///      then another engine operation.
contract AtomicPublisher {
    function depositPublishThenRedeem(
        MockCore core,
        VedaVaultRegistry registry,
        MockTeller newTeller,
        MockAccountant newAccountant,
        uint256 newRate,
        address receiver
    ) external {
        core.deposit(10);
        registry.publish(
            ITeller(address(newTeller)),
            IBoringQueue(address(0)),
            IAccountant(address(newAccountant)),
            IBoringSolver(address(0)),
            newRate,
            newRate,
            1 days
        );
        core.redeem(5, receiver, 1);
    }
}

contract VedaLockstepEnginePeripheryTest is VedaLockstepEngineTestBase {
    address internal thief = makeAddr("thief");

    // ------------------------------------------------------------------
    // Lockstep
    // ------------------------------------------------------------------

    function testAPublicationReachesEveryEngineInTheSameCallWithoutTheirOwners() public {
        // A second stack on the same vault, owned by someone else.
        address otherOwner = makeAddr("other owner");
        VedaLockstepEngine otherEngine = new VedaLockstepEngine(
            IVedaVaultRegistry(address(registry)), otherOwner, MAX_RATE_AGE, "Other Stack", "vOTHER"
        );
        MockCore otherCore = new MockCore(asset);
        otherCore.setEngine(VedaEngine(address(otherEngine)));
        vm.prank(otherOwner);
        otherEngine.initializeEarnVault(address(otherCore));
        core.setDepositsPaused(false);

        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);
        _publish(newTeller, newQueue, newAccountant, 2e6, 2e6);

        // Neither owner did anything, deposits were never paused, and both engines already use the tuple.
        MockCore[2] memory cores = [core, otherCore];
        VedaLockstepEngine[2] memory engines = [engine, otherEngine];
        for (uint256 i = 0; i < 2; i++) {
            assertEq(address(engines[i].teller()), address(newTeller));
            assertEq(address(engines[i].queue()), address(newQueue));
            assertEq(address(engines[i].accountant()), address(newAccountant));
            assertEq(engines[i].rate(), 2e6);
            asset.mint(address(cores[i]), 20);
            assertEq(cores[i].deposit(20), 10);
            assertEq(engines[i].totalAssets(), 20);
        }
        assertEq(newTeller.bulkDepositCalls(), 2);
        assertEq(teller.bulkDepositCalls(), 0);
    }

    function testTheEngineOwnerHasNoSayInTheModules() public {
        // The activation entry point `VedaEngine` gives its owner does not exist here.
        (bool success,) = address(engine).call(abi.encodeCall(VedaEngine.syncVedaPeriphery, (1, type(uint256).max)));
        assertFalse(success);
        (success,) = address(engine).call(abi.encodeWithSignature("peripheryRegistry()"));
        assertFalse(success);
        assertEq(address(engine.vaultRegistry()), address(registry));
        assertEq(address(engine.teller()), address(registry.teller()));
        assertEq(address(engine.queue()), address(registry.queue()));
        assertEq(address(engine.accountant()), address(registry.accountant()));
    }

    function testARateChangingPublicationInsideOneTransactionStopsTheNextEngineCall() public {
        asset.mint(address(core), 20);
        (MockAccountant newAccountant, MockTeller newTeller,) = _newPeriphery(2e6);
        AtomicPublisher publisher = new AtomicPublisher();
        vault.transferOwnership(address(publisher));

        // The transaction already priced a deposit at the old Accountant's rate, so the exit that follows
        // the publication reverts and takes the publication with it.
        vm.expectRevert(abi.encodeWithSelector(VedaLockstepEngine.RateChangedWithinTransaction.selector, 1e6, 2e6));
        publisher.depositPublishThenRedeem(core, registry, newTeller, newAccountant, 2e6, receiver);
        assertEq(address(registry.accountant()), address(accountant));
        assertEq(vault.balanceOf(address(engine)), 0);

        // A publication that keeps the rate goes through in the same shape.
        (MockAccountant sameRateAccountant, MockTeller sameRateTeller,) = _newPeriphery(1e6);
        publisher.depositPublishThenRedeem(core, registry, sameRateTeller, sameRateAccountant, 1e6, receiver);
        assertEq(address(registry.accountant()), address(sameRateAccountant));
        assertEq(vault.balanceOf(address(engine)), 5);
    }

    // ------------------------------------------------------------------
    // Queues across publications
    // ------------------------------------------------------------------

    function testAnImmediateOnlyVaultGainsQueuedExitsTheMomentAQueueIsPublished() public {
        _publish(teller, MockQueue(address(0)), accountant, 1e6, 1e6);
        assertEq(address(engine.queue()), address(0));
        assertFalse(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));

        asset.mint(address(core), 10);
        assertEq(core.deposit(10), 10);
        assertEq(core.redeem(5, receiver, 5), 5);
        vm.expectRevert(VedaLockstepEngine.QueueUnavailable.selector);
        core.requestRedeem(5, address(asset), 0, 3600);
        assertEq(vault.balanceOf(address(engine)), 5);

        // No pause, no owner call: the engine advertises and serves the Queue at once.
        core.setDepositsPaused(false);
        _publish(teller, queue, accountant, 1e6, 1e6);
        assertTrue(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));
        bytes32 id = core.requestRedeem(5, address(asset), 0, 3600);
        assertEq(engine.claimQueue(id), address(queue));
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
    }

    function testAClaimStaysWithItsQueueAcrossAPublication() public {
        bytes32 id = _request(40);

        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        _publish(newTeller, newQueue, newAccountant, 1e6, 1e6);

        assertEq(engine.claimQueue(id), address(queue));
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.openClaimsByQueue(address(newQueue)), 0);
        assertEq(core.cancelRedeem(id), 40);
        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        (VedaLockstepEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaLockstepEngine.ClaimStatus.Cancelled));
    }

    function testTheStandingShareAllowanceFollowsTheQueueOfTheLatestRequest() public {
        bytes32 oldId = _request(40);
        assertEq(vault.allowance(address(engine), address(queue)), 1);

        // A publication alone moves nothing; the next request does.
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        _publish(newTeller, newQueue, newAccountant, 1e6, 1e6);
        assertEq(vault.allowance(address(engine), address(queue)), 1);
        assertEq(vault.allowance(address(engine), address(newQueue)), 0);

        skip(1);
        bytes32 newId = _request(30);
        assertEq(vault.allowance(address(engine), address(queue)), 0);
        assertEq(vault.allowance(address(engine), address(newQueue)), 1);
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.openClaimsByQueue(address(newQueue)), 1);
        assertEq(engine.unresolvedClaimCount(), 2);

        // Publishing the first Queue again hands the unit back on the next request.
        uint256 rate = accountant.getRate();
        _publish(teller, queue, accountant, rate, rate);
        skip(1);
        bytes32 thirdId = _request(20);
        assertEq(vault.allowance(address(engine), address(queue)), 1);
        assertEq(vault.allowance(address(engine), address(newQueue)), 0);
        assertEq(engine.openClaimsByQueue(address(queue)), 2);

        assertEq(core.cancelRedeem(newId), 30);
        assertEq(core.cancelRedeem(oldId), 40);
        assertEq(core.cancelRedeem(thirdId), 20);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        assertEq(engine.openClaimsByQueue(address(newQueue)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testAnyoneClearsARetiredQueuesStandingUnitWithoutTouchingItsClaims() public {
        bytes32 id = _request(40);
        assertEq(vault.allowance(address(engine), address(queue)), 1);

        // While the Queue is still published there is nothing to clear.
        vm.prank(makeAddr("anyone"));
        engine.clearRetiredQueueAllowance();
        assertEq(vault.allowance(address(engine), address(queue)), 1);

        // The vault goes immediate-only: no request will ever hand the unit over, so anyone clears it.
        _publish(teller, MockQueue(address(0)), accountant, 1e6, 1e6);
        vm.prank(makeAddr("anyone"));
        engine.clearRetiredQueueAllowance();
        assertEq(vault.allowance(address(engine), address(queue)), 0);
        // A second call finds nothing left to clear.
        engine.clearRetiredQueueAllowance();

        // The open claim on that Queue still cancels: returning shares needs no allowance.
        assertEq(core.cancelRedeem(id), 40);
        assertEq(engine.unresolvedClaimCount(), 0);

        // Published again, the Queue gets its unit back from the next request.
        _publish(teller, queue, accountant, 1e6, 1e6);
        skip(1);
        _request(10);
        assertEq(vault.allowance(address(engine), address(queue)), 1);
    }

    function testRemovingTheQueueStopsNewRequestsAndKeepsExistingOnesCancellable() public {
        bytes32 id = _request(40);
        _publish(teller, MockQueue(address(0)), accountant, 1e6, 1e6);

        assertEq(address(engine.queue()), address(0));
        assertFalse(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));
        assertEq(engine.claimQueue(id), address(queue));
        vault.mint(address(engine), 1);
        vm.expectRevert(VedaLockstepEngine.QueueUnavailable.selector);
        core.requestRedeem(1, address(asset), 0, 3600);

        assertEq(core.cancelRedeem(id), 40);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
    }

    function testARequestIdIsNeverReusedAcrossQueues() public {
        bytes32 id = _request(40);
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        _publish(newTeller, newQueue, newAccountant, 1e6, 1e6);

        // A fresh Queue starts its nonce at one, so identical terms in the same block derive the same ID,
        // whether the first claim is still open or already closed.
        vault.mint(address(engine), 40);
        vm.expectRevert(abi.encodeWithSelector(VedaLockstepEngine.DuplicateRequest.selector, id));
        core.requestRedeem(40, address(asset), 0, 3600);
        assertEq(core.cancelRedeem(id), 40);
        vm.expectRevert(abi.encodeWithSelector(VedaLockstepEngine.DuplicateRequest.selector, id));
        core.requestRedeem(40, address(asset), 0, 3600);

        assertEq(vault.balanceOf(address(engine)), 80);
        assertEq(engine.claimQueue(id), address(queue));
        assertEq(engine.openClaimsByQueue(address(newQueue)), 0);
    }

    // ------------------------------------------------------------------
    // A published module that misbehaves
    // ------------------------------------------------------------------

    function testAThievingTellerCannotTakeTheEnginesAssetsOrShares() public {
        asset.mint(address(core), 100);
        assertEq(core.deposit(60), 60);

        ThievingTeller thieving = new ThievingTeller(vault, accountant, thief);
        registry.publish(
            ITeller(address(thieving)),
            IBoringQueue(address(queue)),
            IAccountant(address(accountant)),
            IBoringSolver(stockSolver),
            1,
            type(uint256).max,
            MAX_RATE_AGE
        );

        // Deposit: the engine approved the vault, so the Teller cannot pull the assets anywhere else...
        vm.expectRevert(bytes("ALLOWANCE"));
        core.deposit(40);
        // ...and shares that appear without the vault taking the assets leave the allowance unspent.
        thieving.setMintWithoutPulling(true);
        vm.expectRevert(abi.encodeWithSelector(VedaLockstepEngine.UnexpectedAllowance.selector, address(vault), 41));
        core.deposit(40);

        // Exits: the Teller holds no allowance over the engine's shares.
        vm.expectRevert(bytes("ALLOWANCE"));
        core.redeem(10, receiver, 1);
        vm.expectRevert(bytes("ALLOWANCE"));
        core.withdraw(10, receiver);

        assertEq(asset.balanceOf(thief), 0);
        assertEq(vault.balanceOf(thief), 0);
        assertEq(asset.balanceOf(address(core)), 40);
        assertEq(vault.balanceOf(address(engine)), 60);
    }

    function testAGreedyQueueCannotTakeMoreThanTheRequestedShares() public {
        vault.mint(address(engine), 100);
        GreedyQueue greedy = new GreedyQueue(vault, accountant);
        registry.publish(
            ITeller(address(teller)),
            IBoringQueue(address(greedy)),
            IAccountant(address(accountant)),
            IBoringSolver(stockSolver),
            1,
            type(uint256).max,
            MAX_RATE_AGE
        );

        vm.expectRevert(abi.encodeWithSelector(VedaLockstepEngine.UnexpectedVenueSharesQueued.selector, 40, 41));
        core.requestRedeem(40, address(asset), 0, 3600);
        assertEq(vault.balanceOf(address(engine)), 100);
        assertEq(vault.balanceOf(address(greedy)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testAnAccountantThatStopsReportingItsAgeBlocksDepositsAndFeesButNeverAnExit() public {
        FragileAccountant fragile = new FragileAccountant(vault, address(asset));
        MockTeller fragileTeller = new MockTeller(vault, fragile, address(asset));
        MockQueue fragileQueue = new MockQueue(vault, fragile);
        _publish(fragileTeller, fragileQueue, fragile, 1e6, 1e6);
        asset.mint(address(core), 100);
        assertEq(core.deposit(60), 60);
        assertTrue(engine.isFeeValuationFresh());

        fragile.setBroken(true);

        // New exposure and fee crystallization wait...
        vm.expectRevert(
            abi.encodeWithSelector(VedaLockstepEngine.UnsupportedAccountantFreshness.selector, address(fragile))
        );
        core.deposit(40);
        assertFalse(engine.isFeeValuationFresh());
        vm.expectRevert(
            abi.encodeWithSelector(VedaLockstepEngine.UnsupportedAccountantFreshness.selector, address(fragile))
        );
        engine.accountantRateUpdatedAt();
        // ...while every exit path stays open.
        assertEq(core.redeem(10, receiver, 10), 10);
        assertEq(core.withdraw(10, receiver), 10);
        bytes32 id = core.requestRedeem(20, address(asset), 0, 3600);
        assertEq(core.cancelRedeem(id), 20);
        assertEq(asset.balanceOf(receiver), 20);
    }

    // ------------------------------------------------------------------
    // Construction and binding
    // ------------------------------------------------------------------

    function testAnEngineNeedsAPublishedRegistryAndValidSettings() public {
        VedaVaultRegistry unpublished = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        vm.expectRevert(VedaLockstepEngine.NoPublishedVedaPeriphery.selector);
        new VedaLockstepEngine(IVedaVaultRegistry(address(unpublished)), address(this), MAX_RATE_AGE, "V", "v");

        IVedaVaultRegistry published = IVedaVaultRegistry(address(registry));
        vm.expectRevert(VedaLockstepEngine.InvalidMaxRateAge.selector);
        new VedaLockstepEngine(published, address(this), 0, "V", "v");
        vm.expectRevert(VedaLockstepEngine.EmptyMetadata.selector);
        new VedaLockstepEngine(published, address(this), MAX_RATE_AGE, "", "v");
        vm.expectRevert(VedaLockstepEngine.EmptyMetadata.selector);
        new VedaLockstepEngine(published, address(this), MAX_RATE_AGE, "V", "");
        vm.expectRevert(VedaLockstepEngine.ZeroAddress.selector);
        new VedaLockstepEngine(IVedaVaultRegistry(address(0)), address(this), MAX_RATE_AGE, "V", "v");
        address codeless = makeAddr("codeless");
        vm.expectRevert(abi.encodeWithSelector(VedaLockstepEngine.InvalidVedaPeriphery.selector, codeless));
        new VedaLockstepEngine(IVedaVaultRegistry(codeless), address(this), MAX_RATE_AGE, "V", "v");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VedaLockstepEngine(published, address(0), MAX_RATE_AGE, "V", "v");

        MockBoringVault wideVault = new MockBoringVault(address(asset), 78);
        MockAccountant wideAccountant = new MockAccountant(wideVault, address(asset));
        MockTeller wideTeller = new MockTeller(wideVault, wideAccountant, address(asset));
        VedaVaultRegistry wideRegistry = new VedaVaultRegistry(IBoringVault(address(wideVault)), address(asset));
        wideRegistry.publish(
            ITeller(address(wideTeller)),
            IBoringQueue(address(0)),
            IAccountant(address(wideAccountant)),
            IBoringSolver(address(0)),
            1,
            type(uint256).max,
            MAX_RATE_AGE
        );
        vm.expectRevert(VedaLockstepEngine.InvalidVenueShareDecimals.selector);
        new VedaLockstepEngine(IVedaVaultRegistry(address(wideRegistry)), address(this), MAX_RATE_AGE, "V", "v");
    }

    function testConstructionFixesTheRegistryVaultAndAssetAndSetsOnlyTheVaultsStandingUnit() public view {
        assertEq(address(engine.vaultRegistry()), address(registry));
        assertEq(address(engine.vault()), address(vault));
        assertEq(engine.baseAsset(), address(asset));
        assertEq(engine.asset(), address(asset));
        assertEq(engine.maxRateAge(), MAX_RATE_AGE);
        assertEq(engine.name(), "Veda Vault");
        assertEq(engine.symbol(), "vVAULT");
        assertEq(asset.allowance(address(engine), address(vault)), 1);
        // The Queue is not fixed, so it holds no allowance until a request names it.
        assertEq(vault.allowance(address(engine), address(queue)), 0);
        assertEq(asset.allowance(address(engine), address(teller)), 0);
    }

    function testBindingIsTheOwnersOnceAndNeedsNoRegistryEntry() public {
        VedaLockstepEngine fresh = new VedaLockstepEngine(
            IVedaVaultRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
        address earnVault = makeAddr("earn vault");
        address finalOwner = makeAddr("final owner");

        vm.prank(finalOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, finalOwner));
        fresh.initializeEarnVault(earnVault, finalOwner);
        vm.expectRevert(VedaLockstepEngine.ZeroAddress.selector);
        fresh.initializeEarnVault(address(0), finalOwner);
        vm.expectRevert(VedaLockstepEngine.ZeroAddress.selector);
        fresh.initializeEarnVault(earnVault, address(0));

        // Bound and handed over in one call, with no pending step left behind.
        fresh.initializeEarnVault(earnVault, finalOwner);
        assertEq(fresh.earnVault(), earnVault);
        assertEq(fresh.owner(), finalOwner);
        assertEq(fresh.pendingOwner(), address(0));

        vm.prank(finalOwner);
        vm.expectRevert(VedaLockstepEngine.AlreadyInitialized.selector);
        fresh.initializeEarnVault(makeAddr("another vault"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.initializeEarnVault(makeAddr("another vault"));
    }

    function testAnUnboundEngineServesNoOne() public {
        VedaLockstepEngine fresh = new VedaLockstepEngine(
            IVedaVaultRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
        vm.expectRevert(VedaLockstepEngine.EarnVaultNotSet.selector);
        fresh.deposit(1);
        vm.expectRevert(VedaLockstepEngine.EarnVaultNotSet.selector);
        fresh.redeem(1, receiver, 1);
        vm.expectRevert(VedaLockstepEngine.EarnVaultNotSet.selector);
        fresh.withdraw(1, receiver);
    }
}
// forge-lint: disable-end(multi-contract-file,erc20-unchecked-transfer)
