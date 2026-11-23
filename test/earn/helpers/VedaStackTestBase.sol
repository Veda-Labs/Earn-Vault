// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnFactory } from "../../../src/earn/core/EarnFactory.sol";
import { EarnFees } from "../../../src/earn/core/EarnFees.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { VedaForwardingSolver } from "../../../src/earn/engines/veda/VedaForwardingSolver.sol";
import { VedaAuthorityOverlay } from "../../../src/earn/engines/veda/shared/VedaAuthorityOverlay.sol";
import { VedaLockstepEngine } from "../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaRoleGranter } from "../../../src/earn/engines/veda/shared/VedaRoleGranter.sol";
import {
    VedaForwardingSolverDeployer,
    VedaLockstepEngineDeployer
} from "../../../src/earn/engines/veda/shared/VedaStackDeployers.sol";
import { VedaStackFactory } from "../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { VedaTellerLister } from "../../../src/earn/engines/veda/shared/VedaTellerLister.sol";
import { VedaVaultAccessRegistry } from "../../../src/earn/engines/veda/shared/VedaVaultAccessRegistry.sol";
import { VedaVaultRegistry } from "../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { DistributorConfig } from "../../../src/interfaces/earn/EarnVaultTypes.sol";
import {
    IVedaStackAccess,
    IVedaStackAuthorizer,
    IVedaTellerLister,
    IVedaVaultRegistry
} from "../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { TIP403_REGISTRY_ADDRESS } from "../../../src/interfaces/external/tempo/ITIP403Registry.sol";
import { IAccountant } from "../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../src/interfaces/external/veda/IBoringVault.sol";
import {
    IAuth,
    IAuthority,
    IBoringVaultCustody,
    IRolesAuthority
} from "../../../src/interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../src/interfaces/external/veda/ITeller.sol";
import { ITellerAllowlist } from "../../../src/interfaces/external/veda/ITellerAllowlist.sol";
import { VedaRedeemRequest } from "../../../src/interfaces/external/veda/VedaTypes.sol";
import { earnVaultTestNoFees } from "./EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "./EarnVaultTestDeployer.sol";
import {
    AllowlistQueue,
    AllowlistTeller,
    AuthedBoringVault,
    AuthedQueue,
    AuthedSolver,
    AuthedTeller,
    MockRolesAuthority
} from "./VedaAuthMocks.sol";
import { MockAccountant, MockAsset, MockBoringVault } from "./VedaEngineMocks.sol";
import { StackMockShareToken, StackMockTip20Factory, StackMockTip403Registry } from "./VedaStackMocks.sol";

/// @dev A finalized Veda vault as it runs in production: no owner on the vault or its periphery, one
///      RolesAuthority owned by a timelock, and every gated function asking its own authority. On top
///      of it, the canonical Earn core and a {VedaStackFactory}. The two concrete bases below differ only
///      in how the factory's authorizations reach the Teller, Queue and stock solver.
abstract contract VedaStackTestBase is Test {
    uint64 internal constant MAX_RATE_AGE = 1 days;

    // Role numbers of the fixture's existing role table.
    uint8 internal constant MINTER_ROLE = 2;
    uint8 internal constant BURNER_ROLE = 3;
    uint8 internal constant OWNER_ROLE = 8;
    uint8 internal constant QUEUE_ROLE = 10;
    uint8 internal constant STOCK_SOLVER_ROLE = 11;
    /// @dev The role every pre-existing `VedaEngine` on the vault holds.
    uint8 internal constant LEGACY_ENGINE_ROLE = 12;
    uint8 internal constant PAUSER_ROLE = 14;
    uint8 internal constant PAUSE_ALL_ROLE = 16;

    /// @dev The timelock: owns the RolesAuthority and holds the owner role.
    address internal admin = makeAddr("timelock");
    address internal pauser = makeAddr("pauser safe");
    address internal operator = makeAddr("operator");
    address internal stackOwner = makeAddr("stack owner");
    address internal forwarderOwner = makeAddr("forwarder owner");
    address internal treasury = makeAddr("treasury");
    address internal solverBot = makeAddr("solver bot");
    address internal user = makeAddr("user");
    address internal receiver = makeAddr("receiver");
    address internal stranger = makeAddr("stranger");
    /// @dev Stands for a `VedaEngine` already live on the vault, authorized the way they are today.
    address internal legacyEngine = makeAddr("legacy engine");

    MockAsset internal asset;
    MockRolesAuthority internal rolesAuthority;
    AuthedBoringVault internal vault;
    MockAccountant internal accountant;
    AuthedTeller internal teller;
    AuthedQueue internal queue;
    AuthedSolver internal solver;

    VedaVaultRegistry internal registry;
    EarnFactory internal earnFactory;
    StackMockTip20Factory internal tip20Factory;
    VedaLockstepEngineDeployer internal engineDeployer;
    VedaForwardingSolverDeployer internal forwarderDeployer;
    IVedaStackAuthorizer internal authorizer;
    /// @dev Zero unless a variant's Teller keeps an account allowlist.
    IVedaTellerLister internal tellerLister;
    VedaStackFactory internal factory;

    function setUp() public virtual {
        _deployVeda();
        _deployEarnCore();
        registry = _newRegistry();
        _publish(teller, queue, solver);
        engineDeployer = new VedaLockstepEngineDeployer();
        forwarderDeployer = new VedaForwardingSolverDeployer();
        _deployAuthorizerAndFactory();
        _adminSetup();
    }

    // ------------------------------------------------------------------
    // What a variant supplies
    // ------------------------------------------------------------------

    function _newRegistry() internal virtual returns (VedaVaultRegistry);

    /// @dev Sets `authorizer` and `factory`. Anyone may deploy these; neither holds a permission yet.
    function _deployAuthorizerAndFactory() internal virtual;

    /// @dev The vault administrator's one-time setup, after which stacks need no transaction from it.
    function _adminSetup() internal virtual;

    /// @dev Called as the administrator before it publishes new modules: whatever lets the vault's Earn
    /// stacks use them. A zero Queue comes with a zero solver.
    function _admitModules(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal virtual;

    // ------------------------------------------------------------------
    // Fixture
    // ------------------------------------------------------------------

    function _deployVeda() internal {
        asset = new MockAsset();
        rolesAuthority = new MockRolesAuthority(admin, address(0));
        vault = new AuthedBoringVault(address(0), address(rolesAuthority), 6);
        accountant = new MockAccountant(MockBoringVault(address(vault)), address(asset));
        teller = _newTeller();
        (queue, solver) = _newExitRail(address(accountant));

        vm.startPrank(admin);
        rolesAuthority.setRoleCapability(MINTER_ROLE, address(vault), IBoringVaultCustody.enter.selector, true);
        rolesAuthority.setRoleCapability(BURNER_ROLE, address(vault), IBoringVaultCustody.exit.selector, true);
        _grantTellerVaultRoles(teller);
        _grantStockSolverRoles(teller, queue, solver);

        // The timelock's own role: custody and every authority pointer, as on a live vault.
        rolesAuthority.setUserRole(admin, OWNER_ROLE, true);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(vault), _manageSelector(), true);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(vault), IAuth.setAuthority.selector, true);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(teller), IAuth.setAuthority.selector, true);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(queue), IAuth.setAuthority.selector, true);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(solver), IAuth.setAuthority.selector, true);
        rolesAuthority.setUserRole(pauser, PAUSER_ROLE, true);
        rolesAuthority.setUserRole(pauser, PAUSE_ALL_ROLE, true);

        // Engines already live on the vault hold role 12 and must keep working untouched.
        rolesAuthority.setRoleCapability(LEGACY_ENGINE_ROLE, address(teller), ITeller.bulkDeposit.selector, true);
        rolesAuthority.setRoleCapability(LEGACY_ENGINE_ROLE, address(teller), ITeller.bulkWithdraw.selector, true);
        rolesAuthority.setRoleCapability(
            LEGACY_ENGINE_ROLE, address(queue), IBoringQueue.requestOnChainWithdraw.selector, true
        );
        rolesAuthority.setRoleCapability(
            LEGACY_ENGINE_ROLE, address(queue), IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector, true
        );
        rolesAuthority.setUserRole(legacyEngine, LEGACY_ENGINE_ROLE, true);
        _configureVeda();
        vm.stopPrank();
    }

    /// @dev Called as the administrator once the vault's modules exist: whatever else this variant's
    /// vault has in place before Earn arrives.
    function _configureVeda() internal virtual { }

    /// @dev The kind of Teller this variant's vault runs: by default one that gates callers only.
    function _newTeller() internal virtual returns (AuthedTeller) {
        return new AuthedTeller(address(0), address(rolesAuthority), vault, address(accountant));
    }

    function _newQueue(address accountant_) internal virtual returns (AuthedQueue) {
        return new AuthedQueue(address(0), address(rolesAuthority), vault, accountant_);
    }

    function _newExitRail(address accountant_) internal returns (AuthedQueue newQueue, AuthedSolver newSolver) {
        newQueue = _newQueue(accountant_);
        newSolver = new AuthedSolver(address(0), address(rolesAuthority), newQueue);
    }

    /// @dev Called as the administrator: lets a Teller mint and burn vault shares.
    function _grantTellerVaultRoles(AuthedTeller teller_) internal {
        rolesAuthority.setUserRole(address(teller_), MINTER_ROLE, true);
        rolesAuthority.setUserRole(address(teller_), BURNER_ROLE, true);
    }

    /// @dev Called as the administrator: lets a stock solver redeem through the Teller and solve its
    /// Queue, and lets the Queue call the solver back.
    function _grantStockSolverRoles(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal {
        rolesAuthority.setRoleCapability(STOCK_SOLVER_ROLE, address(teller_), ITeller.bulkWithdraw.selector, true);
        rolesAuthority.setRoleCapability(
            STOCK_SOLVER_ROLE, address(queue_), AuthedQueue.solveOnChainWithdraws.selector, true
        );
        rolesAuthority.setUserRole(address(solver_), STOCK_SOLVER_ROLE, true);
        rolesAuthority.setRoleCapability(QUEUE_ROLE, address(solver_), AuthedSolver.boringSolve.selector, true);
        rolesAuthority.setUserRole(address(queue_), QUEUE_ROLE, true);
    }

    function _deployEarnCore() internal {
        tip20Factory = new StackMockTip20Factory();
        earnFactory = new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
        vm.etch(TIP403_REGISTRY_ADDRESS, address(new StackMockTip403Registry()).code);
    }

    function _publish(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal {
        vm.prank(admin);
        registry.publish(
            ITeller(address(teller_)),
            IBoringQueue(address(queue_)),
            IAccountant(address(accountant)),
            IBoringSolver(address(solver_)),
            1,
            type(uint256).max,
            MAX_RATE_AGE
        );
    }

    /// @dev A publication as the administrator runs it: the Veda-side roles of the new modules, the Earn
    /// stacks' access to them, then the registry.
    function _rotate(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal {
        vm.startPrank(admin);
        _grantTellerVaultRoles(teller_);
        if (address(queue_) != address(0)) _grantStockSolverRoles(teller_, queue_, solver_);
        _admitModules(teller_, queue_, solver_);
        vm.stopPrank();
        _publish(teller_, queue_, solver_);
    }

    function _factoryConfig() internal view returns (VedaStackFactory.Config memory) {
        return VedaStackFactory.Config({
            registry: IVedaVaultRegistry(address(registry)),
            authorizer: authorizer,
            tellerLister: tellerLister,
            earnFactory: earnFactory,
            earnFactoryCodeHash: address(earnFactory).codehash,
            engineDeployer: engineDeployer,
            engineDeployerCodeHash: address(engineDeployer).codehash,
            forwarderDeployer: forwarderDeployer,
            forwarderDeployerCodeHash: address(forwarderDeployer).codehash,
            forwarderOwner: forwarderOwner,
            forwarderTreasury: treasury,
            operator: operator
        });
    }

    /// @dev Called as the administrator: lets the vault's pausers use the factory's reducing functions.
    function _grantPauserCapabilities() internal {
        for (uint256 i = 0; i < 2; i++) {
            uint8 role = i == 0 ? PAUSER_ROLE : PAUSE_ALL_ROLE;
            rolesAuthority.setRoleCapability(role, address(factory), VedaStackFactory.revokeEngine.selector, true);
            rolesAuthority.setRoleCapability(role, address(factory), VedaStackFactory.revokeForwarder.selector, true);
            rolesAuthority.setRoleCapability(role, address(factory), VedaStackFactory.pauseRegistrations.selector, true);
        }
    }

    // ------------------------------------------------------------------
    // Building and using stacks
    // ------------------------------------------------------------------

    function _engineParams() internal pure returns (VedaStackFactory.EngineParams memory) {
        return VedaStackFactory.EngineParams({ name: "Veda Vault", symbol: "vVAULT", maxRateAge: MAX_RATE_AGE });
    }

    function _coreParams(bytes32 deploymentId) internal view returns (EarnFactory.DeployParams memory) {
        return EarnFactory.DeployParams({
            deploymentId: deploymentId,
            engine: address(0),
            owner: stackOwner,
            controls: EarnVaultTestDeployer.defaultControls(stackOwner),
            distributorConfig: DistributorConfig(address(0), 0),
            fees: earnVaultTestNoFees(),
            transferPolicyId: 0
        });
    }

    function _createStack(bytes32 deploymentId)
        internal
        returns (VedaLockstepEngine engine, EarnVault earnVault, StackMockShareToken earnShare)
    {
        vm.prank(operator);
        (address engine_, address earnVault_, address earnShare_) =
            factory.createStack(_engineParams(), _coreParams(deploymentId), address(0));
        return (VedaLockstepEngine(engine_), EarnVault(earnVault_), StackMockShareToken(earnShare_));
    }

    function _deposit(EarnVault earnVault, address account, uint256 assets) internal returns (uint256 earnShares) {
        asset.mint(account, assets);
        vm.startPrank(account);
        asset.approve(address(earnVault), assets);
        earnShares = earnVault.deposit(assets, account, 1);
        vm.stopPrank();
    }

    function _requestRedeem(EarnVault earnVault, StackMockShareToken earnShare, address account, uint256 earnShares)
        internal
        returns (bytes32 requestId)
    {
        bytes memory engineData = abi.encode(
            VedaRedeemRequest({ assetOut: address(asset), discountBps: 0, secondsToDeadline: 3600, minQueuedAssets: 1 })
        );
        vm.startPrank(account);
        earnShare.approve(address(earnVault), earnShares);
        requestId = earnVault.requestRedeem(earnShares, engineData, account);
        vm.stopPrank();
    }

    /// @dev The forwarding solver's owner allowlists a solver, which then settles `requestId`.
    function _solve(VedaForwardingSolver forwarder, bytes32 requestId) internal returns (uint256 forwarded) {
        vm.prank(forwarderOwner);
        forwarder.setAuthorizedSolver(solverBot, true);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = requestId;
        vm.prank(solverBot);
        forwarded = forwarder.solveAndForward(ids, false);
    }

    function _manageSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("manage(address,bytes,uint256)"));
    }

    function _manageBatchSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("manage(address[],bytes[],uint256[])"));
    }

    /// @dev Every function that moves the BoringVault's assets or shares, or changes who may.
    function _custodySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = _manageSelector();
        selectors[1] = _manageBatchSelector();
        selectors[2] = IBoringVaultCustody.enter.selector;
        selectors[3] = IBoringVaultCustody.exit.selector;
        selectors[4] = IBoringVaultCustody.setBeforeTransferHook.selector;
        selectors[5] = IAuth.setAuthority.selector;
        selectors[6] = IAuth.transferOwnership.selector;
    }

    /// @dev Every function that changes the RolesAuthority's role table or who controls it.
    function _roleAdminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IRolesAuthority.setUserRole.selector;
        selectors[1] = IRolesAuthority.setRoleCapability.selector;
        selectors[2] = IRolesAuthority.setPublicCapability.selector;
        selectors[3] = IAuth.setAuthority.selector;
        selectors[4] = IAuth.transferOwnership.selector;
    }

    /// @dev Whether the module's own authority admits `account` for `functionSig`, as the module would ask.
    function _canCall(address account, address target, bytes4 functionSig) internal view returns (bool) {
        return IAuthority(IAuth(target).authority()).canCall(account, target, functionSig);
    }
}

/// @dev Authorization through RolesAuthority roles: a {VedaRoleGranter} is the RolesAuthority's authority.
abstract contract VedaRoleStackTestBase is VedaStackTestBase {
    uint8 internal constant EARN_ENGINE_ROLE = 40;
    uint8 internal constant EARN_FORWARDER_ROLE = 41;

    VedaRoleGranter internal granter;

    function _newRegistry() internal virtual override returns (VedaVaultRegistry) {
        return new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
    }

    function _deployAuthorizerAndFactory() internal virtual override {
        granter = new VedaRoleGranter(
            IRolesAuthority(address(rolesAuthority)),
            IVedaVaultRegistry(address(registry)),
            EARN_ENGINE_ROLE,
            EARN_FORWARDER_ROLE
        );
        authorizer = IVedaStackAuthorizer(address(granter));
        factory = new VedaStackFactory(_factoryConfig());
    }

    function _adminSetup() internal virtual override {
        vm.startPrank(admin);
        _grantEarnRoleCapabilities(teller, queue, solver);
        // The one change to the RolesAuthority itself: it now asks the granter about calls on itself.
        rolesAuthority.setAuthority(address(granter));
        granter.setFactory(address(factory), true);
        _grantPauserCapabilities();
        // The batch's last call names the registry it published on and the factory it named, and undoes
        // the whole setup unless the granter serves both and could grant both roles.
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        vm.stopPrank();
    }

    function _admitModules(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal virtual override {
        _grantEarnRoleCapabilities(teller_, queue_, solver_);
    }

    /// @dev Called as the administrator: what the two dedicated Earn roles may call, and nothing else.
    function _grantEarnRoleCapabilities(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal {
        rolesAuthority.setRoleCapability(EARN_ENGINE_ROLE, address(teller_), ITeller.bulkDeposit.selector, true);
        rolesAuthority.setRoleCapability(EARN_ENGINE_ROLE, address(teller_), ITeller.bulkWithdraw.selector, true);
        if (address(queue_) != address(0)) {
            rolesAuthority.setRoleCapability(
                EARN_ENGINE_ROLE, address(queue_), IBoringQueue.requestOnChainWithdraw.selector, true
            );
            rolesAuthority.setRoleCapability(
                EARN_ENGINE_ROLE, address(queue_), IBoringQueue.cancelOnChainWithdrawUsingRequestId.selector, true
            );
            rolesAuthority.setRoleCapability(
                EARN_FORWARDER_ROLE, address(solver_), IBoringSolver.boringRedeemSolve.selector, true
            );
        }
    }
}

/// @dev Authorization through a read-only {VedaAuthorityOverlay} over a {VedaVaultAccessRegistry}:
///      nothing writes to the RolesAuthority.
abstract contract VedaOverlayStackTestBase is VedaStackTestBase {
    VedaVaultAccessRegistry internal accessRegistry;
    VedaAuthorityOverlay internal overlay;

    function _newRegistry() internal override returns (VedaVaultRegistry) {
        accessRegistry = new VedaVaultAccessRegistry(IBoringVault(address(vault)), address(asset));
        return accessRegistry;
    }

    function _deployAuthorizerAndFactory() internal override {
        authorizer = IVedaStackAuthorizer(address(accessRegistry));
        factory = new VedaStackFactory(_factoryConfig());
        // Anyone may have the registry create its overlay; the administrator only binds it.
        vm.prank(stranger);
        overlay = VedaAuthorityOverlay(accessRegistry.createOverlay());
    }

    function _adminSetup() internal override {
        vm.startPrank(admin);
        // Three live contracts are repointed; the BoringVault keeps the RolesAuthority.
        teller.setAuthority(address(overlay));
        queue.setAuthority(address(overlay));
        solver.setAuthority(address(overlay));
        accessRegistry.setOverlay(address(overlay));
        accessRegistry.setFactory(address(factory), true);
        _grantPauserCapabilities();
        vm.stopPrank();
    }

    function _admitModules(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal override {
        _pointAtOverlay(address(teller_));
        if (address(queue_) != address(0)) {
            _pointAtOverlay(address(queue_));
            _pointAtOverlay(address(solver_));
        }
    }

    /// @dev Called as the administrator, through its owner role, as on a finalized module.
    function _pointAtOverlay(address module) internal {
        if (IAuth(module).authority() == address(overlay)) return;
        rolesAuthority.setRoleCapability(OWNER_ROLE, module, IAuth.setAuthority.selector, true);
        IAuth(module).setAuthority(address(overlay));
    }
}

/// @dev A vault whose Teller is open to every caller and admits by account instead: both bulk paths
///      are public, the Teller enforces its allowlist in both directions, and its Queue applies the same
///      list to request owners. A {VedaTellerLister} puts each engine on the list as the factory builds
///      it. The Queue and the stock solver still gate callers, so the role granter serves those.
abstract contract VedaAllowlistStackTestBase is VedaRoleStackTestBase {
    /// @dev Held by the lister alone: `setAllowedAccounts` on the Teller and nothing else.
    uint8 internal constant LISTER_ROLE = 42;

    VedaTellerLister internal lister;

    function _newTeller() internal virtual override returns (AuthedTeller) {
        return new AllowlistTeller(address(0), address(rolesAuthority), vault, address(accountant));
    }

    function _newQueue(address accountant_) internal virtual override returns (AuthedQueue) {
        return new AllowlistQueue(address(0), address(rolesAuthority), vault, accountant_);
    }

    function _configureVeda() internal virtual override {
        _configureAllowlist(teller, queue, solver);
    }

    /// @dev Called as the administrator: opens a Teller's bulk paths to every caller, turns its list on
    /// in both directions, lists the stock solver, which redeems every settled request, and binds the
    /// Queue to that list. A zero Queue comes with a zero solver.
    function _configureAllowlist(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal {
        AllowlistTeller listed = AllowlistTeller(address(teller_));
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(listed), AllowlistTeller.setAllowlistEnabled.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(listed), ITellerAllowlist.setAllowedAccounts.selector, true
        );
        rolesAuthority.setPublicCapability(address(listed), ITeller.bulkDeposit.selector, true);
        rolesAuthority.setPublicCapability(address(listed), ITeller.bulkWithdraw.selector, true);
        listed.setAllowlistEnabled(true, true);
        if (address(queue_) != address(0)) {
            _list(listed, address(solver_));
            rolesAuthority.setRoleCapability(OWNER_ROLE, address(queue_), AllowlistQueue.setTeller.selector, true);
            AllowlistQueue(address(queue_)).setTeller(address(listed));
        }
    }

    /// @dev Called as the administrator: lists one account directly, as the administrator always can.
    function _list(AllowlistTeller teller_, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        teller_.setAllowedAccounts(accounts, true);
    }

    function _deployAuthorizerAndFactory() internal override {
        lister = new VedaTellerLister(IVedaVaultRegistry(address(registry)));
        tellerLister = IVedaTellerLister(address(lister));
        super._deployAuthorizerAndFactory();
    }

    function _adminSetup() internal override {
        super._adminSetup();
        vm.startPrank(admin);
        _grantListerCapability(teller);
        rolesAuthority.setUserRole(address(lister), LISTER_ROLE, true);
        lister.setFactory(address(factory), true);
        // As with the granter: the batch's last call undoes it unless the lister serves this registry
        // and this factory and can write the published Teller's list.
        lister.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
        vm.stopPrank();
    }

    function _admitModules(AuthedTeller teller_, AuthedQueue queue_, AuthedSolver solver_) internal override {
        super._admitModules(teller_, queue_, solver_);
        if (!AllowlistTeller(address(teller_)).depositAllowlistEnabled()) {
            _configureAllowlist(teller_, queue_, solver_);
        }
        _grantListerCapability(teller_);
    }

    /// @dev Called as the administrator: the one function the lister's role reaches on a Teller.
    function _grantListerCapability(AuthedTeller teller_) internal {
        rolesAuthority.setRoleCapability(
            LISTER_ROLE, address(teller_), ITellerAllowlist.setAllowedAccounts.selector, true
        );
    }
}
