// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// The role granter is the one new contract that can write to a vault's RolesAuthority, so these tests
// pin down everything it can and cannot do, then fuzz the whole stack factory against that bound.
// forge-lint: disable-start(multi-contract-file,unsafe-typecast)
import { Test } from "forge-std/Test.sol";
import { EarnFactory } from "../../../../../src/earn/core/EarnFactory.sol";
import { VedaLockstepEngine } from "../../../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaRoleGranter } from "../../../../../src/earn/engines/veda/shared/VedaRoleGranter.sol";
import { VedaStackFactory } from "../../../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { VedaVaultRegistry } from "../../../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import {
    IVedaStackAuthorizer,
    IVedaVaultRegistry
} from "../../../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IBoringVault } from "../../../../../src/interfaces/external/veda/IBoringVault.sol";
import { IAuth, IRolesAuthority } from "../../../../../src/interfaces/external/veda/IRolesAuthority.sol";
import { ITeller } from "../../../../../src/interfaces/external/veda/ITeller.sol";
import { MockRolesAuthority } from "../../../helpers/VedaAuthMocks.sol";
import { VedaRoleStackTestBase } from "../../../helpers/VedaStackTestBase.sol";

contract VedaRoleGranterTest is VedaRoleStackTestBase {
    /// @dev Any contract will do as a grantee; the granter only requires code.
    address internal grantee;

    function setUp() public override {
        super.setUp();
        grantee = address(new MockRolesAuthority(address(this), address(0)));
    }

    // ------------------------------------------------------------------
    // The authority surface
    // ------------------------------------------------------------------

    function testFuzzCanCallAdmitsOnlyItselfCallingSetUserRoleOnItsRolesAuthority(
        address caller,
        address target,
        bytes4 functionSig
    ) public view {
        bool expected = caller == address(granter) && target == address(rolesAuthority)
            && functionSig == IRolesAuthority.setUserRole.selector;
        assertEq(granter.canCall(caller, target, functionSig), expected);
    }

    function testOnlyTheOwnerAndTheGranterCanChangeRolesAndOnlyTheOwnerEverythingElse() public {
        assertEq(rolesAuthority.authority(), address(granter));
        assertEq(rolesAuthority.owner(), admin);

        // The granter's whole reach into the RolesAuthority is setUserRole.
        bytes4[] memory roleAdmin = _roleAdminSelectors();
        for (uint256 i = 0; i < roleAdmin.length; i++) {
            bool isSetUserRole = roleAdmin[i] == IRolesAuthority.setUserRole.selector;
            assertEq(granter.canCall(address(granter), address(rolesAuthority), roleAdmin[i]), isSetUserRole);
        }
        vm.startPrank(address(granter));
        vm.expectRevert(bytes("UNAUTHORIZED"));
        rolesAuthority.setRoleCapability(EARN_ENGINE_ROLE, address(vault), _manageSelector(), true);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        rolesAuthority.setPublicCapability(address(vault), _manageSelector(), true);
        vm.expectRevert();
        rolesAuthority.setAuthority(address(granter));
        vm.expectRevert(bytes("UNAUTHORIZED"));
        rolesAuthority.transferOwnership(address(granter));
        vm.stopPrank();

        // No role holder gains a path to the role table, whatever role it holds.
        address[6] memory others = [stranger, operator, pauser, address(factory), legacyEngine, address(teller)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(bytes("UNAUTHORIZED"));
            rolesAuthority.setUserRole(others[i], OWNER_ROLE, true);
            vm.expectRevert(bytes("UNAUTHORIZED"));
            rolesAuthority.setRoleCapability(PAUSER_ROLE, address(vault), _manageSelector(), true);
            vm.stopPrank();
        }

        // The owner keeps every power, including withdrawing the granter's path.
        vm.startPrank(admin);
        rolesAuthority.setUserRole(stranger, PAUSER_ROLE, true);
        rolesAuthority.setAuthority(address(0));
        vm.stopPrank();
        assertTrue(rolesAuthority.doesUserHaveRole(stranger, PAUSER_ROLE));
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityAuthority.selector, address(0)));
        granter.setEngineAuthorized(grantee, true);
    }

    function testAContractThatPointsItsAuthorityAtTheGranterByMistakeAdmitsNoOne() public {
        // The granter answers for one target only, so it opens nothing on any other contract.
        vm.prank(admin);
        rolesAuthority.setRoleCapability(OWNER_ROLE, address(teller), IAuth.setAuthority.selector, true);
        vm.prank(admin);
        teller.setAuthority(address(granter));

        address[3] memory callers = [address(granter), address(factory), admin];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(bytes("UNAUTHORIZED"));
            teller.bulkWithdraw(address(asset), 1, 0, callers[i]);
        }
    }

    // ------------------------------------------------------------------
    // Two roles, one caller
    // ------------------------------------------------------------------

    function testOnlyTheFactoryCallsIt() public {
        address[5] memory callers = [stranger, operator, admin, pauser, stackOwner];
        for (uint256 i = 0; i < callers.length; i++) {
            bytes memory notFactory = abi.encodeWithSelector(VedaRoleGranter.NotFactory.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(notFactory);
            granter.setEngineAuthorized(grantee, true);
            vm.expectRevert(notFactory);
            granter.setEngineAuthorized(grantee, false);
            vm.expectRevert(notFactory);
            granter.setForwarderAuthorized(grantee, true);
            vm.expectRevert(notFactory);
            granter.setForwarderAuthorized(grantee, false);
            vm.stopPrank();
        }
        assertEq(rolesAuthority.getUserRoles(grantee), bytes32(0));
    }

    function testFuzzAGrantOrRevocationChangesExactlyOneFixedRoleBit(bytes32 priorRoles, bool forwarder) public {
        // Whatever roles the account already holds, apart from the two Earn roles.
        priorRoles &= ~bytes32((uint256(1) << EARN_ENGINE_ROLE) | (uint256(1) << EARN_FORWARDER_ROLE));
        vm.startPrank(admin);
        for (uint256 role = 0; role < 256; role++) {
            if ((uint256(priorRoles) >> role) & 1 != 0) rolesAuthority.setUserRole(grantee, uint8(role), true);
        }
        vm.stopPrank();
        uint8 expectedRole = forwarder ? EARN_FORWARDER_ROLE : EARN_ENGINE_ROLE;

        vm.prank(address(factory));
        if (forwarder) granter.setForwarderAuthorized(grantee, true);
        else granter.setEngineAuthorized(grantee, true);
        assertEq(rolesAuthority.getUserRoles(grantee), priorRoles | bytes32(uint256(1) << expectedRole));

        vm.prank(address(factory));
        if (forwarder) granter.setForwarderAuthorized(grantee, false);
        else granter.setEngineAuthorized(grantee, false);
        assertEq(rolesAuthority.getUserRoles(grantee), priorRoles);
    }

    function testItsWiringIsFixedAndValidatedAtConstruction() public {
        assertEq(address(granter.rolesAuthority()), address(rolesAuthority));
        assertEq(address(granter.registry()), address(registry));
        assertEq(granter.vault(), address(vault));
        assertEq(granter.engineRole(), EARN_ENGINE_ROLE);
        assertEq(granter.forwarderRole(), EARN_FORWARDER_ROLE);

        IRolesAuthority authority = IRolesAuthority(address(rolesAuthority));
        IVedaVaultRegistry vaultRegistry = IVedaVaultRegistry(address(registry));
        vm.expectRevert(VedaRoleGranter.ZeroAddress.selector);
        new VedaRoleGranter(IRolesAuthority(address(0)), vaultRegistry, 40, 41);
        vm.expectRevert(VedaRoleGranter.ZeroAddress.selector);
        new VedaRoleGranter(authority, IVedaVaultRegistry(address(0)), 40, 41);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.InvalidAuthorizerWiring.selector, stranger));
        new VedaRoleGranter(IRolesAuthority(stranger), vaultRegistry, 40, 41);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.InvalidAuthorizerWiring.selector, stranger));
        new VedaRoleGranter(authority, IVedaVaultRegistry(stranger), 40, 41);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.SameRole.selector, 40));
        new VedaRoleGranter(authority, vaultRegistry, 40, 40);
    }

    // ------------------------------------------------------------------
    // Which factories
    // ------------------------------------------------------------------

    function testOnlyTheRolesAuthoritysOwnerNamesAFactory() public {
        VedaStackFactory second = new VedaStackFactory(_factoryConfig());
        address[5] memory callers = [stranger, operator, pauser, address(factory), address(granter)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityOwner.selector, callers[i]));
            granter.setFactory(address(second), true);
            vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityOwner.selector, callers[i]));
            granter.setFactory(address(factory), false);
            vm.stopPrank();
        }
        assertFalse(granter.isFactory(address(second)));
        assertTrue(granter.isFactory(address(factory)));

        // With the owner gone, no one names a factory, the zero address included.
        vm.prank(admin);
        rolesAuthority.transferOwnership(address(0));
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityOwner.selector, address(0)));
        granter.setFactory(address(second), true);
    }

    function testAFactoryIsNamedOnlyIfItBuildsOnThisRegistryThroughThisGranter() public {
        // A genuine factory, wired to a second registry for the same vault that the administrator never
        // published on. Its engines would read that registry's modules, so it must not be nameable.
        VedaVaultRegistry lookalike = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        VedaStackFactory.Config memory config = _factoryConfig();
        config.registry = IVedaVaultRegistry(address(lookalike));
        address otherRegistryFactory = address(new VedaStackFactory(config));

        // A genuine factory on the right registry that asks a different granter.
        VedaRoleGranter otherGranter = new VedaRoleGranter(
            IRolesAuthority(address(rolesAuthority)), IVedaVaultRegistry(address(registry)), 40, 41
        );
        config = _factoryConfig();
        config.authorizer = IVedaStackAuthorizer(address(otherGranter));
        address otherGranterFactory = address(new VedaStackFactory(config));

        vm.startPrank(admin);
        address[3] memory refused = [otherRegistryFactory, otherGranterFactory, stranger];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.FactoryNotWired.selector, refused[i]));
            granter.setFactory(refused[i], true);
        }
        // A contract that is no stack factory at all.
        vm.expectRevert();
        granter.setFactory(address(teller), true);
        vm.stopPrank();
    }

    function testAFactoryThatIsNoLongerNamedCanNeitherGrantNorRevoke() public {
        vm.prank(address(factory));
        granter.setEngineAuthorized(grantee, true);
        vm.prank(admin);
        granter.setFactory(address(factory), false);

        vm.startPrank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotFactory.selector, address(factory)));
        granter.setEngineAuthorized(grantee, false);
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotFactory.selector, address(factory)));
        granter.setForwarderAuthorized(grantee, true);
        vm.stopPrank();
        // The role stays until the owner clears it.
        assertTrue(rolesAuthority.doesUserHaveRole(grantee, EARN_ENGINE_ROLE));
        vm.prank(admin);
        rolesAuthority.setUserRole(grantee, EARN_ENGINE_ROLE, false);
        assertFalse(rolesAuthority.doesUserHaveRole(grantee, EARN_ENGINE_ROLE));
    }

    // ------------------------------------------------------------------
    // What it refuses before a grant
    // ------------------------------------------------------------------

    function testARoleIsNeverGrantedToAKeyOrAnEmptyAddress() public {
        address[2] memory accounts = [address(0), stranger];
        for (uint256 i = 0; i < accounts.length; i++) {
            vm.startPrank(address(factory));
            vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.InvalidAccount.selector, accounts[i]));
            granter.setEngineAuthorized(accounts[i], true);
            vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.InvalidAccount.selector, accounts[i]));
            granter.setForwarderAuthorized(accounts[i], true);
            vm.stopPrank();
        }
    }

    function testGrantsStopUnlessTheGranterIsTheRolesAuthoritysAuthorityButRevocationStillWorks() public {
        vm.prank(address(factory));
        granter.setEngineAuthorized(grantee, true);

        // The administrator moves to a self-governed role table and gives the granter a registrar role
        // there. The granter could now reach setUserRole, but so could any holder of that role, so it
        // refuses to grant. It still revokes.
        uint8 registrarRole = 50;
        vm.startPrank(admin);
        rolesAuthority.setAuthority(address(rolesAuthority));
        rolesAuthority.setRoleCapability(
            registrarRole, address(rolesAuthority), IRolesAuthority.setUserRole.selector, true
        );
        rolesAuthority.setUserRole(address(granter), registrarRole, true);
        vm.stopPrank();
        assertFalse(granter.isGrantSafe(EARN_ENGINE_ROLE));

        address second = address(new MockRolesAuthority(address(this), address(0)));
        vm.startPrank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityAuthority.selector, address(rolesAuthority))
        );
        granter.setEngineAuthorized(second, true);
        granter.setEngineAuthorized(grantee, false);
        vm.stopPrank();
        assertFalse(rolesAuthority.doesUserHaveRole(grantee, EARN_ENGINE_ROLE));
        assertFalse(rolesAuthority.doesUserHaveRole(second, EARN_ENGINE_ROLE));
    }

    function testARoleThatReachesCustodyOrRoleAdministrationIsNeverGranted() public {
        assertTrue(granter.isGrantSafe(EARN_ENGINE_ROLE));
        assertTrue(granter.isGrantSafe(EARN_FORWARDER_ROLE));

        bytes4[] memory custody = _custodySelectors();
        for (uint256 i = 0; i < custody.length; i++) {
            _assertGrantRefusedWhileRoleReaches(address(vault), custody[i]);
        }
        bytes4[] memory roleAdmin = _roleAdminSelectors();
        for (uint256 i = 0; i < roleAdmin.length; i++) {
            _assertGrantRefusedWhileRoleReaches(address(rolesAuthority), roleAdmin[i]);
        }
    }

    function testGrantsStopOnceNoOwnerCouldCutTheGranterOff() public {
        // With the owner gone, pointing the authority elsewhere is impossible, so nothing more is granted.
        vm.prank(admin);
        rolesAuthority.transferOwnership(address(0));
        assertFalse(granter.isGrantSafe(EARN_ENGINE_ROLE));

        vm.prank(address(factory));
        vm.expectRevert(VedaRoleGranter.RolesAuthorityHasNoOwner.selector);
        granter.setEngineAuthorized(grantee, true);
        vm.expectRevert(VedaRoleGranter.RolesAuthorityHasNoOwner.selector);
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(factory));
    }

    function testGrantsStopOnceTheVaultAnswersToAnotherRolesAuthority() public {
        // The role table the granter inspects must be the one the BoringVault obeys.
        MockRolesAuthority replacement = new MockRolesAuthority(admin, address(0));
        vm.prank(admin);
        vault.setAuthority(address(replacement));
        assertFalse(granter.isGrantSafe(EARN_ENGINE_ROLE));

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.VaultAuthorityMismatch.selector, address(replacement)));
        granter.setForwarderAuthorized(grantee, true);
        // Roles already granted can still be taken away.
        vm.prank(address(factory));
        granter.setForwarderAuthorized(grantee, false);
    }

    function testTheSetupAssertionPassesOnlyForACompleteAndSafeSetup() public {
        IVedaVaultRegistry published = IVedaVaultRegistry(address(registry));
        // The fixture's setup batch already ended with this call.
        granter.assertSetup(published, address(factory));

        // Before the administrator points the RolesAuthority at the granter.
        vm.prank(admin);
        rolesAuthority.setAuthority(address(0));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.NotRolesAuthorityAuthority.selector, address(0)));
        granter.assertSetup(published, address(factory));
        vm.prank(admin);
        rolesAuthority.setAuthority(address(granter));

        // Either Earn role reaching custody.
        vm.prank(admin);
        rolesAuthority.setRoleCapability(EARN_FORWARDER_ROLE, address(vault), _manageSelector(), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                VedaRoleGranter.RoleReachesProtectedFunction.selector,
                EARN_FORWARDER_ROLE,
                address(vault),
                _manageSelector()
            )
        );
        granter.assertSetup(published, address(factory));
        vm.prank(admin);
        rolesAuthority.setRoleCapability(EARN_FORWARDER_ROLE, address(vault), _manageSelector(), false);
        granter.assertSetup(published, address(factory));
    }

    function testTheSetupAssertionTiesTheGranterToThePublishedRegistryAndTheNamedFactory() public {
        // A granter built for some other registry of the same vault: the batch names the registry it
        // actually published on, so the mismatch undoes it.
        VedaVaultRegistry lookalike = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        vm.expectRevert(
            abi.encodeWithSelector(VedaRoleGranter.RegistryMismatch.selector, address(lookalike), address(registry))
        );
        granter.assertSetup(IVedaVaultRegistry(address(lookalike)), address(factory));

        // A factory the administrator did not name, however it is wired.
        VedaStackFactory unnamed = new VedaStackFactory(_factoryConfig());
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.FactoryNotWired.selector, address(unnamed)));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), address(unnamed));
        vm.expectRevert(abi.encodeWithSelector(VedaRoleGranter.FactoryNotWired.selector, stranger));
        granter.assertSetup(IVedaVaultRegistry(address(registry)), stranger);
    }

    function testTheProtectedSelectorsAreTheBoringVaultsOwn() public pure {
        // The custody selectors the granter refuses are those of the BoringVault's real signatures, which
        // take the asset as an address; the simplified four-argument fixtures elsewhere would not match.
        bytes4[] memory custody = _custodySelectors();
        assertEq(custody[0], bytes4(keccak256("manage(address,bytes,uint256)")));
        assertEq(custody[1], bytes4(keccak256("manage(address[],bytes[],uint256[])")));
        assertEq(custody[2], bytes4(keccak256("enter(address,address,uint256,address,uint256)")));
        assertEq(custody[2], bytes4(uint32(0x39d6ba32)));
        assertEq(custody[3], bytes4(keccak256("exit(address,address,uint256,address,uint256)")));
        assertEq(custody[3], bytes4(uint32(0x18457e61)));
        assertEq(custody[4], bytes4(keccak256("setBeforeTransferHook(address)")));
        assertEq(custody[5], bytes4(keccak256("setAuthority(address)")));
        assertEq(custody[6], bytes4(keccak256("transferOwnership(address)")));
    }

    function testARevocationThatDoesNotTakeEffectReverts() public {
        // A RolesAuthority that ignores the write must not be reported as updated.
        vm.prank(address(factory));
        granter.setEngineAuthorized(grantee, true);
        vm.mockCall(
            address(rolesAuthority), abi.encodeCall(IRolesAuthority.setUserRole, (grantee, EARN_ENGINE_ROLE, false)), ""
        );
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(VedaRoleGranter.RoleUpdateFailed.selector, grantee, EARN_ENGINE_ROLE, false)
        );
        granter.setEngineAuthorized(grantee, false);
    }

    function _assertGrantRefusedWhileRoleReaches(address target, bytes4 functionSig) private {
        uint8[2] memory roles = [EARN_ENGINE_ROLE, EARN_FORWARDER_ROLE];
        for (uint256 i = 0; i < roles.length; i++) {
            vm.prank(admin);
            rolesAuthority.setRoleCapability(roles[i], target, functionSig, true);
            assertFalse(granter.isGrantSafe(roles[i]));

            vm.prank(address(factory));
            vm.expectRevert(
                abi.encodeWithSelector(
                    VedaRoleGranter.RoleReachesProtectedFunction.selector, roles[i], target, functionSig
                )
            );
            if (i == 0) granter.setEngineAuthorized(grantee, true);
            else granter.setForwarderAuthorized(grantee, true);

            vm.prank(admin);
            rolesAuthority.setRoleCapability(roles[i], target, functionSig, false);
            assertTrue(granter.isGrantSafe(roles[i]));
        }
        assertEq(rolesAuthority.getUserRoles(grantee), bytes32(0));
    }
}

/// @dev Drives every external entry point of the factory and the granter from every kind of caller.
contract VedaRoleStackHandler is Test {
    VedaStackFactory public immutable factory;
    VedaRoleGranter public immutable granter;
    address[] public actors;
    address[] public engines;
    address[] public forwarders;
    uint256 private _nonce;

    constructor(VedaStackFactory factory_, VedaRoleGranter granter_, address[] memory actors_) {
        factory = factory_;
        granter = granter_;
        actors = actors_;
    }

    function createStack(uint256 actorSeed, address owner, address policyAdmin) external {
        vm.prank(_actor(actorSeed));
        try factory.createStack(_nextJob(), _engineParams(), _coreParams(owner), policyAdmin) returns (
            address engine, address, address
        ) {
            _track(engine);
        } catch { }
    }

    function deployEngine(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        try factory.deployEngine(_nextJob(), _engineParams()) returns (address engine) {
            engines.push(engine);
        } catch { }
    }

    function finalizeStack(uint256 actorSeed, uint256 engineSeed, address owner) external {
        if (engines.length == 0) return;
        address engine = engines[engineSeed % engines.length];
        vm.prank(_actor(actorSeed));
        try factory.finalizeStack(engine, _coreParams(owner), address(0)) {
            _trackForwarder(engine);
        } catch { }
    }

    function deployForwarder(uint256 actorSeed, uint256 engineSeed) external {
        if (engines.length == 0) return;
        vm.prank(_actor(actorSeed));
        try factory.deployForwarder(engines[engineSeed % engines.length]) returns (address forwarder) {
            forwarders.push(forwarder);
        } catch { }
    }

    function revokeOrReinstateEngine(uint256 actorSeed, uint256 engineSeed, bool revoke) external {
        if (engines.length == 0) return;
        address engine = engines[engineSeed % engines.length];
        vm.prank(_actor(actorSeed));
        if (revoke) {
            try factory.revokeEngine(engine) { } catch { }
        } else {
            try factory.reinstateEngine(engine) { } catch { }
        }
    }

    function revokeOrReinstateForwarder(uint256 actorSeed, uint256 forwarderSeed, bool revoke) external {
        if (forwarders.length == 0) return;
        address forwarder = forwarders[forwarderSeed % forwarders.length];
        vm.prank(_actor(actorSeed));
        if (revoke) {
            try factory.revokeForwarder(forwarder) { } catch { }
        } else {
            try factory.reinstateForwarder(forwarder) { } catch { }
        }
    }

    function pauseOrResume(uint256 actorSeed, bool pause) external {
        vm.prank(_actor(actorSeed));
        if (pause) {
            try factory.pauseRegistrations() { } catch { }
        } else {
            try factory.resumeRegistrations() { } catch { }
        }
    }

    /// @dev Anyone tries the granter directly, on any account, for either role.
    function callGranter(uint256 actorSeed, address account, bool forwarder, bool enabled) external {
        vm.prank(_actor(actorSeed));
        if (forwarder) {
            try granter.setForwarderAuthorized(account, enabled) { } catch { }
        } else {
            try granter.setEngineAuthorized(account, enabled) { } catch { }
        }
    }

    function engineCount() external view returns (uint256) {
        return engines.length;
    }

    function forwarderCount() external view returns (uint256) {
        return forwarders.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _track(address engine) private {
        engines.push(engine);
        _trackForwarder(engine);
    }

    function _trackForwarder(address engine) private {
        address forwarder = factory.stack(engine).forwarder;
        if (forwarder != address(0)) forwarders.push(forwarder);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _nextJob() private returns (bytes32) {
        return keccak256(abi.encode("handler job", _nonce++));
    }

    function _engineParams() private pure returns (VedaStackFactory.EngineParams memory) {
        return VedaStackFactory.EngineParams({ name: "Veda Vault", symbol: "vVAULT", maxRateAge: 1 days });
    }

    function _coreParams(address owner) private returns (EarnFactory.DeployParams memory params) {
        params.deploymentId = keccak256(abi.encode("handler", _nonce++));
        params.owner = owner;
    }
}

contract VedaRoleStackInvariantTest is VedaRoleStackTestBase {
    VedaRoleStackHandler private handler;
    address[] private _actors;
    mapping(address => bytes32) private _baselineRoles;
    bytes32 private _earnRoleBits;

    function setUp() public override {
        super.setUp();
        _actors = [operator, admin, pauser, stranger, stackOwner];
        handler = new VedaRoleStackHandler(factory, granter, _actors);
        _earnRoleBits = bytes32((uint256(1) << EARN_ENGINE_ROLE) | (uint256(1) << EARN_FORWARDER_ROLE));

        address[10] memory watched = _watched();
        for (uint256 i = 0; i < watched.length; i++) {
            _baselineRoles[watched[i]] = rolesAuthority.getUserRoles(watched[i]);
        }
        targetContract(address(handler));
    }

    /// @dev The handler's calls do land when their rightful caller makes them, so the invariant below is
    ///      checked over built, revoked and reinstated stacks and not over reverts alone.
    function testHandlerCallsLandForTheirRightfulCallers() public {
        handler.createStack(0, stackOwner, address(0)); // operator
        handler.deployEngine(0);
        handler.finalizeStack(0, 1, stackOwner);
        assertEq(handler.engineCount(), 2);
        assertEq(handler.forwarderCount(), 2);
        address engine = handler.engines(0);
        handler.revokeOrReinstateEngine(2, 0, true); // pauser
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Revoked));
        handler.revokeOrReinstateEngine(1, 0, false); // administrator
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Active));
        handler.deployForwarder(0, 0);
        assertEq(handler.forwarderCount(), 3);
        // A stranger's attempt on the granter changes nothing.
        handler.callGranter(3, engine, false, false);
        assertTrue(rolesAuthority.doesUserHaveRole(engine, EARN_ENGINE_ROLE));
    }

    /// @dev Whatever anyone calls, the role table changes only in the two Earn role bits, and only for
    ///      contracts the factory built and currently records as active.
    function invariant_onlyFactoryBuiltContractsHoldEarnRolesAndNothingElseChanges() public view {
        // The RolesAuthority's own control never moves.
        assertEq(rolesAuthority.owner(), admin);
        assertEq(rolesAuthority.authority(), address(granter));

        // No pre-existing principal gains or loses a role.
        address[10] memory watched = _watched();
        for (uint256 i = 0; i < watched.length; i++) {
            assertEq(rolesAuthority.getUserRoles(watched[i]), _baselineRoles[watched[i]]);
        }

        // An engine holds the engine role exactly while its record is active, and no other role.
        for (uint256 i = 0; i < handler.engineCount(); i++) {
            address engine = handler.engines(i);
            bool active = factory.stack(engine).status == VedaStackFactory.EngineStatus.Active;
            bytes32 expected = active ? bytes32(uint256(1) << EARN_ENGINE_ROLE) : bytes32(0);
            assertEq(rolesAuthority.getUserRoles(engine), expected);
            // An active engine is bound, handed over, and usable on the Teller; nothing else is.
            assertEq(_canCall(engine, address(teller), ITeller.bulkDeposit.selector), active);
            if (active) {
                assertTrue(VedaLockstepEngine(engine).earnVault() != address(0));
                assertTrue(VedaLockstepEngine(engine).owner() != address(factory));
            }
        }

        // A forwarding solver holds the forwarder role exactly while its record is active.
        for (uint256 i = 0; i < handler.forwarderCount(); i++) {
            address forwarder = handler.forwarders(i);
            bool active = factory.forwarderRecord(forwarder).status == VedaStackFactory.ForwarderStatus.Active;
            bytes32 expected = active ? bytes32(uint256(1) << EARN_FORWARDER_ROLE) : bytes32(0);
            assertEq(rolesAuthority.getUserRoles(forwarder), expected);
        }

        // Neither Earn role, nor anything the factory touches, reaches custody.
        bytes4[] memory custody = _custodySelectors();
        for (uint256 i = 0; i < custody.length; i++) {
            assertFalse(rolesAuthority.doesRoleHaveCapability(EARN_ENGINE_ROLE, address(vault), custody[i]));
            assertFalse(rolesAuthority.doesRoleHaveCapability(EARN_FORWARDER_ROLE, address(vault), custody[i]));
            assertFalse(rolesAuthority.canCall(address(factory), address(vault), custody[i]));
            assertFalse(rolesAuthority.canCall(address(granter), address(vault), custody[i]));
        }
    }

    function _watched() private view returns (address[10] memory) {
        return [
            admin,
            pauser,
            operator,
            stranger,
            stackOwner,
            legacyEngine,
            address(teller),
            address(queue),
            address(solver),
            address(factory)
        ];
    }
}
// forge-lint: disable-end(multi-contract-file,unsafe-typecast)
