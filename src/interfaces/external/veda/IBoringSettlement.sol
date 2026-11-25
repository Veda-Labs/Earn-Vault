// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { OnChainWithdraw } from "./VedaTypes.sol";

/// @notice The two calls inside a stock solver's redeem settlement that {IBoringQueue} and
///         {IBoringSolver} do not declare: the solver's call on the Queue, and the Queue's call back
///         on the solver. Declared for their selectors, which a module's authority is asked about.
/// @dev Kept apart from those two interfaces so that their sources, which the released engine and
///      forwarding solver are built from, do not change.
interface IBoringSettlement {
    /// @notice BoringOnChainQueue.solveOnChainWithdraws, called by the stock solver.
    function solveOnChainWithdraws(OnChainWithdraw[] calldata requests, bytes calldata solveData, address solver)
        external;

    /// @notice BoringSolver.boringSolve, called by the Queue during a solve.
    function boringSolve(
        address initiator,
        address boringVault,
        address solveAsset,
        uint256 totalShares,
        uint256 requiredAssets,
        bytes calldata solveData
    ) external;
}
