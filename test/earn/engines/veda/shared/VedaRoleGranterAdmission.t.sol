// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { VedaEngine } from "../../../../../src/earn/engines/veda/VedaEngine.sol";
import { AllowlistTeller, AuthedQueue, AuthedSolver, AuthedTeller } from "../../../helpers/VedaAuthMocks.sol";
import { VedaAllowlistStackTestBase } from "../../../helpers/VedaStackTestBase.sol";

/// @dev Teller membership is a separate policy. The factory and role granter neither manage it nor
///      claim that authority checks alone prove a deposit or exit can succeed.
contract VedaRoleGranterAdmissionTest is VedaAllowlistStackTestBase {
    function testFactoryGrantsRoleWithoutListingEngine() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(keccak256("separate admission"));
        AllowlistTeller listed = AllowlistTeller(address(teller));

        assertTrue(rolesAuthority.doesUserHaveRole(address(engine), EARN_ENGINE_ROLE));
        assertTrue(factory.isEngineReady(address(engine))); // Authority only, not Teller membership.
        assertFalse(listed.allowedAccounts(address(engine)));

        asset.mint(user, 1e6);
        vm.startPrank(user);
        asset.approve(address(earnVault), 1e6);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "NOT_ALLOWED"));
        earnVault.deposit(1e6, user, 1);
        vm.stopPrank();

        vm.prank(admin);
        _list(listed, address(engine));
        assertTrue(listed.allowedAccounts(address(engine)));
        assertGt(_deposit(earnVault, user, 1e6), 0);
    }

    function testRevokingRoleDoesNotWriteTellerMembership() public {
        (VedaEngine engine,,) = _createStack(keccak256("independent revocation"));
        AllowlistTeller listed = AllowlistTeller(address(teller));
        vm.prank(admin);
        _list(listed, address(engine));
        assertTrue(factory.canEngineUseTeller(address(engine)));

        vm.prank(pauser);
        factory.revokeEngine(address(engine));

        assertFalse(rolesAuthority.doesUserHaveRole(address(engine), EARN_ENGINE_ROLE));
        assertTrue(listed.allowedAccounts(address(engine)));
        assertFalse(factory.canEngineUseTeller(address(engine)));
        assertFalse(factory.isEngineReady(address(engine)));
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "UNAUTHORIZED"));
        teller.bulkDeposit(address(asset), 1, 0, address(engine));
    }

    function testPublicationAndRotationDoNotRequireEngineListing() public {
        (VedaEngine engine, EarnVault earnVault,) = _createStack(keccak256("separate rotation"));
        AuthedTeller next = _newTeller();
        (AuthedQueue nextQueue, AuthedSolver nextSolver) = _newExitRail(address(accountant));

        _rotate(next, nextQueue, nextSolver);
        _activate(engine, earnVault);

        assertEq(address(engine.teller()), address(next));
        assertFalse(AllowlistTeller(address(next)).allowedAccounts(address(engine)));
        assertTrue(factory.isEngineReady(address(engine))); // Role permission on the new modules.
    }
}
