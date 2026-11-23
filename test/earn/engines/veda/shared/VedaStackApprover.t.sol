// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// With an approver set, the operator's key alone admits no stack: every stack needs a second key's
// signature over exactly the settings it is built with. These tests pin down what that signature
// covers, that it is used once, and that it holds through the one-call and the two-call build.
// forge-lint: disable-start(multi-contract-file)
import { EarnFactory } from "../../../../../src/earn/core/EarnFactory.sol";
import { EarnVault } from "../../../../../src/earn/core/EarnVault.sol";
import { VedaLockstepEngine } from "../../../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaStackFactory } from "../../../../../src/earn/engines/veda/shared/VedaStackFactory.sol";
import { VedaRoleStackTestBase } from "../../../helpers/VedaStackTestBase.sol";

/// @dev A contract approver: it accepts a signature made by its one signer, as a Safe would.
contract ContractApprover {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signature, (uint8, bytes32, bytes32));
        return ecrecover(digest, v, r, s) == signer ? this.isValidSignature.selector : bytes4(0);
    }
}

contract VedaStackApproverTest is VedaRoleStackTestBase {
    bytes32 internal constant STACK_A = keccak256("stack-a");
    bytes32 internal constant STACK_B = keccak256("stack-b");
    bytes32 internal constant JOB = keccak256("job-one");

    uint256 internal approverKey;
    uint256 internal otherKey;

    function setUp() public override {
        (approver, approverKey) = makeAddrAndKey("approver");
        (, otherKey) = makeAddrAndKey("another key");
        super.setUp();
    }

    // ------------------------------------------------------------------
    // Two keys to build
    // ------------------------------------------------------------------

    function testTheOperatorBuildsOnlyWhatTheApproverSigned() public {
        assertEq(factory.approver(), approver);

        // The operator's key alone builds no stack.
        vm.startPrank(operator);
        vm.expectRevert(VedaStackFactory.ApprovalRequired.selector);
        factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0));
        address pending = factory.deployEngine(keccak256("job-two"), _engineParams());
        vm.expectRevert(VedaStackFactory.ApprovalRequired.selector);
        factory.finalizeStack(pending, _coreParams(STACK_B), address(0));
        vm.stopPrank();

        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        vm.prank(operator);
        (address engine, address earnVault,) =
            factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertEq(_deposit(EarnVault(earnVault), user, 10e6), 10e6);

        // The approver's key alone builds nothing either.
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotOperator.selector, approver));
        factory.createStack(keccak256("job-three"), _engineParams(), _coreParams(STACK_B), address(0), approval);
    }

    function testAnApprovalCoversEverySettingAndNothingElse() public {
        uint256 deadline = _inAnHour();
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), deadline);

        // Another owner.
        EarnFactory.DeployParams memory core = _coreParams(STACK_A);
        core.owner = stranger;
        _expectRefused(JOB, _engineParams(), core, address(0), approval);
        // Another cap, deep in the core's controls.
        core = _coreParams(STACK_A);
        core.controls.maxManagedAssets = 1;
        _expectRefused(JOB, _engineParams(), core, address(0), approval);
        // Another guardian.
        core = _coreParams(STACK_A);
        core.controls.emergencyGuardian = stranger;
        _expectRefused(JOB, _engineParams(), core, address(0), approval);
        // Another transfer policy, either way of choosing one.
        core = _coreParams(STACK_A);
        core.transferPolicyId = 7;
        _expectRefused(JOB, _engineParams(), core, address(0), approval);
        _expectRefused(JOB, _engineParams(), _coreParams(STACK_A), stranger, approval);
        // Another rate age bound, name or symbol.
        VedaStackFactory.EngineParams memory engineParams = _engineParams();
        engineParams.maxRateAge = 30 days;
        _expectRefused(JOB, engineParams, _coreParams(STACK_A), address(0), approval);
        engineParams = _engineParams();
        engineParams.name = "Another Vault";
        _expectRefused(JOB, engineParams, _coreParams(STACK_A), address(0), approval);
        engineParams = _engineParams();
        engineParams.symbol = "OTHER";
        _expectRefused(JOB, engineParams, _coreParams(STACK_A), address(0), approval);
        // Another job.
        _expectRefused(keccak256("job-two"), _engineParams(), _coreParams(STACK_A), address(0), approval);
        // Another deadline than the one signed.
        VedaStackFactory.Approval memory stretched =
            VedaStackFactory.Approval({ deadline: deadline + 1 days, signature: approval.signature });
        _expectRefused(JOB, _engineParams(), _coreParams(STACK_A), address(0), stretched);
        // Another signer.
        VedaStackFactory.Approval memory forged =
            _approve(otherKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), deadline);
        _expectRefused(JOB, _engineParams(), _coreParams(STACK_A), address(0), forged);
        // A signature that is no signature.
        VedaStackFactory.Approval memory empty = VedaStackFactory.Approval({ deadline: deadline, signature: "" });
        _expectRefused(JOB, _engineParams(), _coreParams(STACK_A), address(0), empty);
        assertEq(factory.engineCount(), 0);

        // Exactly what was signed builds.
        vm.prank(operator);
        factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        assertEq(factory.engineCount(), 1);
    }

    function testAnApprovalIsForOneFactoryOneChainOneUseAndALimitedTime() public {
        uint256 deadline = _inAnHour();
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), deadline);

        // Another factory with the same approver, operator and vault.
        VedaStackFactory other = new VedaStackFactory(_factoryConfig());
        vm.prank(admin);
        granter.setFactory(address(other), true);
        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.InvalidApproval.selector);
        other.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);

        // Another chain.
        uint256 chainId = vm.getChainId();
        vm.chainId(chainId + 1);
        _expectRefused(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        vm.chainId(chainId);

        // After its deadline.
        vm.warp(deadline + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.ApprovalExpired.selector, deadline));
        factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        vm.warp(deadline);

        // Once.
        vm.startPrank(operator);
        (address engine,,) = factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.JobAlreadyBuilt.selector, JOB, engine));
        factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // The two-call build
    // ------------------------------------------------------------------

    function testAnApprovalHoldsThroughTheTwoCallBuildForTheEngineItNames() public {
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());

        vm.startPrank(operator);
        address engine = factory.deployEngine(JOB, _engineParams());
        // An engine deployed under another job cannot borrow this job's approval.
        address elsewhere = factory.deployEngine(keccak256("job-two"), _engineParams());
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.JobNotThisEngine.selector, JOB, elsewhere));
        factory.finalizeStack(elsewhere, _coreParams(STACK_A), address(0), JOB, approval);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.JobNotThisEngine.selector, keccak256("no job"), engine));
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0), keccak256("no job"), approval);
        // Other core settings than the signed ones.
        EarnFactory.DeployParams memory other = _coreParams(STACK_A);
        other.owner = stranger;
        vm.expectRevert(VedaStackFactory.InvalidApproval.selector);
        factory.finalizeStack(engine, other, address(0), JOB, approval);
        vm.stopPrank();

        // Someone creates the same core first, so this finalize can never land under that deployment
        // id. The approval does not name the id, which only salts addresses, so the retry needs no
        // new signature.
        EarnFactory.DeployParams memory squatted = _coreParams(STACK_A);
        squatted.engine = engine;
        vm.prank(stranger);
        earnFactory.deploy(squatted);
        vm.startPrank(operator);
        vm.expectRevert();
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0), JOB, approval);
        (address earnVault,) = factory.finalizeStack(engine, _coreParams(STACK_B), address(0), JOB, approval);
        vm.stopPrank();
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Active));
        assertEq(_deposit(EarnVault(earnVault), user, 10e6), 10e6);
    }

    function testAnEnginePlantedUnderAJobWithOtherSettingsCannotUseItsApproval() public {
        // The approver signed a one-day rate age bound. Whoever holds the operator key deploys the
        // job's engine with another, hoping the approval will carry it.
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        VedaStackFactory.EngineParams memory planted = _engineParams();
        planted.maxRateAge = 365 days;

        vm.startPrank(operator);
        address engine = factory.deployEngine(JOB, planted);
        vm.expectRevert(VedaStackFactory.InvalidApproval.selector);
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0), JOB, approval);
        vm.stopPrank();
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Pending));
        assertEq(VedaLockstepEngine(engine).earnVault(), address(0));

        // The planted engine is set aside; the stack is built under a new job with a new approval.
        vm.prank(pauser);
        factory.discardEngine(engine);
        bytes32 job = keccak256("job-two");
        approval = _approve(approverKey, job, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        vm.prank(operator);
        factory.createStack(job, _engineParams(), _coreParams(STACK_A), address(0), approval);
    }

    function testAnApprovalExpiresAndADiscardedEngineStaysDiscardedInTheTwoCallBuild() public {
        uint256 deadline = _inAnHour();
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), deadline);
        vm.prank(operator);
        address engine = factory.deployEngine(JOB, _engineParams());

        vm.warp(deadline + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.ApprovalExpired.selector, deadline));
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0), JOB, approval);
        vm.warp(deadline);

        // A valid approval does not bring back an engine a pauser set aside.
        vm.prank(pauser);
        factory.discardEngine(engine);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.EngineNotPending.selector, engine));
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0), JOB, approval);
    }

    function testAnEngineDeployedBeforeAnApproverWasSetStillNeedsItsSignature() public {
        vm.prank(admin);
        factory.setApprover(address(0));
        vm.prank(operator);
        address engine = factory.deployEngine(JOB, _engineParams());
        vm.prank(admin);
        factory.setApprover(approver);

        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.ApprovalRequired.selector);
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0));
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        vm.prank(operator);
        factory.finalizeStack(engine, _coreParams(STACK_A), address(0), JOB, approval);
        assertEq(uint256(factory.stack(engine).status), uint256(VedaStackFactory.EngineStatus.Active));
    }

    function testTheDigestIsTheEip712HashAWalletWouldCompute() public view {
        // Built here from the published type strings, independently of the factory's own code.
        VedaStackFactory.EngineParams memory engineParams = _engineParams();
        EarnFactory.DeployParams memory core = _coreParams(STACK_A);
        uint256 deadline = 1_900_000_000;
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VedaStackFactory"),
                keccak256("1"),
                block.chainid,
                address(factory)
            )
        );
        EarnFactory.DeployParams memory settings = _coreParams(bytes32(0));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "StackApproval(bytes32 jobId,address owner,uint64 maxRateAge,uint64 transferPolicyId,address newTransferPolicyAdmin,bytes32 settingsHash,uint256 deadline)"
                ),
                JOB,
                stackOwner,
                uint256(MAX_RATE_AGE),
                uint256(0),
                stranger,
                keccak256(abi.encode(engineParams, settings)),
                deadline
            )
        );
        assertEq(
            factory.approvalDigest(JOB, engineParams, core, stranger, deadline),
            keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, structHash))
        );
    }

    // ------------------------------------------------------------------
    // The approver itself
    // ------------------------------------------------------------------

    function testOnlyTheAdministratorSetsOrRemovesTheApprover() public {
        address[4] memory others = [stranger, operator, pauser, approver];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.NotVaultAdmin.selector, others[i]));
            factory.setApprover(others[i]);
        }

        // Replaced: the old key's signature no longer builds.
        (address newApprover, uint256 newKey) = makeAddrAndKey("new approver");
        VedaStackFactory.Approval memory old =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        vm.prank(admin);
        factory.setApprover(newApprover);
        _expectRefused(JOB, _engineParams(), _coreParams(STACK_A), address(0), old);
        VedaStackFactory.Approval memory fresh =
            _approve(newKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        vm.prank(operator);
        factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), fresh);

        // Removed: the operator alone builds again, with or without an approval attached.
        vm.prank(admin);
        factory.setApprover(address(0));
        vm.startPrank(operator);
        factory.createStack(keccak256("job-two"), _engineParams(), _coreParams(STACK_B), address(0));
        factory.createStack(keccak256("job-three"), _engineParams(), _coreParams(keccak256("stack-c")), address(0), old);
        vm.stopPrank();
        assertEq(factory.engineCount(), 3);
    }

    function testTheApproverIsNeverTheOperatorsKeyOrTheFactory() public {
        // One key in both seats would be one key again.
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidApprover.selector, operator));
        factory.setApprover(operator);
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidApprover.selector, address(factory)));
        factory.setApprover(address(factory));
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidApprover.selector, approver));
        factory.setOperator(approver);
        vm.stopPrank();

        VedaStackFactory.Config memory config = _factoryConfig();
        config.approver = config.operator;
        vm.expectRevert(abi.encodeWithSelector(VedaStackFactory.InvalidApprover.selector, config.operator));
        new VedaStackFactory(config);
    }

    function testAnApproverDoesNotGateForwardersForStacksAlreadyBuilt() public {
        VedaStackFactory.Approval memory approval =
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), _inAnHour());
        vm.startPrank(operator);
        (address engine,,) = factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        // The operator alone still builds a forwarding solver for a stack that exists, which settles
        // nothing until the engine's owner admits it.
        address forwarder = factory.deployForwarder(engine);
        vm.stopPrank();
        assertFalse(VedaLockstepEngine(engine).authorizedForwarder(forwarder));
    }

    function testAContractCanBeTheApprover() public {
        ContractApprover wallet = new ContractApprover(vm.addr(otherKey));
        vm.prank(admin);
        factory.setApprover(address(wallet));

        // The wallet's signer signs; the account that was approver before no longer counts.
        uint256 deadline = _inAnHour();
        _expectRefused(
            JOB,
            _engineParams(),
            _coreParams(STACK_A),
            address(0),
            _approve(approverKey, JOB, _engineParams(), _coreParams(STACK_A), address(0), deadline)
        );
        bytes32 digest = factory.approvalDigest(JOB, _engineParams(), _coreParams(STACK_A), address(0), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, digest);
        VedaStackFactory.Approval memory approval =
            VedaStackFactory.Approval({ deadline: deadline, signature: abi.encode(v, r, s) });
        vm.prank(operator);
        factory.createStack(JOB, _engineParams(), _coreParams(STACK_A), address(0), approval);
        assertEq(factory.engineCount(), 1);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Read through the cheatcode, so the value does not follow a later warp.
    function _inAnHour() private view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    function _approve(
        uint256 key,
        bytes32 job,
        VedaStackFactory.EngineParams memory engineParams,
        EarnFactory.DeployParams memory core,
        address newTransferPolicyAdmin,
        uint256 deadline
    ) private view returns (VedaStackFactory.Approval memory) {
        bytes32 digest = factory.approvalDigest(job, engineParams, core, newTransferPolicyAdmin, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return VedaStackFactory.Approval({ deadline: deadline, signature: abi.encodePacked(r, s, v) });
    }

    function _expectRefused(
        bytes32 job,
        VedaStackFactory.EngineParams memory engineParams,
        EarnFactory.DeployParams memory core,
        address newTransferPolicyAdmin,
        VedaStackFactory.Approval memory approval
    ) private {
        vm.prank(operator);
        vm.expectRevert(VedaStackFactory.InvalidApproval.selector);
        factory.createStack(job, engineParams, core, newTransferPolicyAdmin, approval);
    }
}
// forge-lint: disable-end(multi-contract-file)
