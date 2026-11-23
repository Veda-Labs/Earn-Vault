// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The account allowlist of a Veda Teller that has one. Such a Teller checks the account whose
///         position changes, whoever the caller is: the share recipient on a deposit and the share
///         owner on a withdrawal. A Queue bound to the Teller checks each request's owner the same way.
interface ITellerAllowlist {
    function setAllowedAccounts(address[] calldata accounts, bool allowed) external;
    /// @notice Whether `account` is on the list, whether or not the list is enforced.
    function allowedAccounts(address account) external view returns (bool);
    /// @notice Whether the list lets shares be minted to `account`: true while deposits are not enforced.
    function isDepositAllowed(address account) external view returns (bool);
    /// @notice Whether the list lets `account` redeem: true while withdrawals are not enforced.
    function isWithdrawAllowed(address account) external view returns (bool);
}
