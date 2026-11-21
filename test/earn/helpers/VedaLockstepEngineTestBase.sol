// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { VedaEngine } from "../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaLockstepEngine } from "../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol";
import { VedaVaultRegistry } from "../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol";
import { IVedaVaultRegistry } from "../../../src/interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAccountant } from "../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../src/interfaces/external/veda/ITeller.sol";
import { MockAccountant, MockAsset, MockBoringVault, MockCore, MockQueue, MockTeller } from "./VedaEngineMocks.sol";

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

/// @dev The `VedaEngine` test base, rebuilt on a {VedaVaultRegistry} and a {VedaLockstepEngine}. This
///      test owns the mock BoringVault, which is its own authority, so it is the vault's administrator
///      and publishes directly.
abstract contract VedaLockstepEngineTestBase is Test {
    uint64 internal constant MAX_RATE_AGE = 1 days;

    MockAsset asset;
    MockBoringVault vault;
    MockAccountant accountant;
    MockTeller teller;
    MockQueue queue;
    address stockSolver;
    VedaVaultRegistry registry;
    VedaLockstepEngine engine;
    MockCore core;
    address receiver = address(0xB0B);

    function setUp() public virtual {
        _deployVedaStack(6);
        _bindCore();
        core.setDepositsPaused(true);
        engine.setAuthorizedForwarder(address(this), true);
    }

    /// @dev Deploys a fresh asset, a BoringVault with `decimals`-decimal shares, its full periphery, the
    /// vault's registry with that periphery published, and an engine owned by this test. The caller
    /// binds the engine to an EarnVault.
    function _deployVedaStack(uint8 decimals) internal {
        asset = new MockAsset();
        vault = new PermissiveBoringVault(address(asset), decimals);
        accountant = new MockAccountant(vault, address(asset));
        teller = new MockTeller(vault, accountant, address(asset));
        queue = new MockQueue(vault, accountant);
        stockSolver = address(new MockStockSolver());
        registry = new VedaVaultRegistry(IBoringVault(address(vault)), address(asset));
        _publish(teller, queue, accountant, 1, type(uint256).max);
        engine = new VedaLockstepEngine(
            IVedaVaultRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
    }

    /// @dev Binds the current engine to a fresh MockCore, which drives only the functions that
    /// `VedaEngine` and `VedaLockstepEngine` share.
    function _bindCore() internal {
        core = new MockCore(asset);
        core.setEngine(VedaEngine(address(engine)));
        engine.initializeEarnVault(address(core));
    }

    function _newPeriphery(uint256 rate_)
        internal
        returns (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue)
    {
        newAccountant = new MockAccountant(vault, address(asset));
        newAccountant.setRate(rate_);
        newTeller = new MockTeller(vault, newAccountant, address(asset));
        newQueue = new MockQueue(vault, newAccountant);
    }

    /// @dev Publishes a tuple, which every engine of the vault uses from this call on. A zero Queue
    /// publishes no stock solver.
    function _publish(
        MockTeller newTeller,
        MockQueue newQueue,
        MockAccountant newAccountant,
        uint256 minRate,
        uint256 maxRate
    ) internal {
        registry.publish(
            ITeller(address(newTeller)),
            IBoringQueue(address(newQueue)),
            IAccountant(address(newAccountant)),
            IBoringSolver(address(newQueue) == address(0) ? address(0) : stockSolver),
            minRate,
            maxRate,
            MAX_RATE_AGE
        );
    }

    function _request(uint128 shares) internal returns (bytes32 id) {
        vault.mint(address(engine), shares);
        id = core.requestRedeem(shares, address(asset), 0, 3600);
    }

    function _ids(bytes32 id) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = id;
    }
}
