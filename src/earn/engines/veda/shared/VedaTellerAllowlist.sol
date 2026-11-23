// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITellerAllowlist } from "../../../../interfaces/external/veda/ITellerAllowlist.sol";

/// @title VedaTellerAllowlist
/// @notice Reads a Teller's account allowlist without assuming the Teller has one. Older Tellers gate
///         callers only, so every read reports whether the Teller answered in the expected shape.
/// @dev Never reverts. A missing function, a revert, or anything but one ABI word holding 0 or 1 (or an
///      address, for {tryQueueTeller}) is reported as unsupported. A caller that reads unsupported as
///      "this Teller has no list" therefore also admits a Teller whose list cannot be read; the
///      modules read here are the ones the vault's administrator published.
library VedaTellerAllowlist {
    function tryIsDepositAllowed(address teller, address account) internal view returns (bool supported, bool allowed) {
        return _tryBool(teller, abi.encodeCall(ITellerAllowlist.isDepositAllowed, (account)));
    }

    function tryIsWithdrawAllowed(address teller, address account)
        internal
        view
        returns (bool supported, bool allowed)
    {
        return _tryBool(teller, abi.encodeCall(ITellerAllowlist.isWithdrawAllowed, (account)));
    }

    /// @notice Whether `account` is on the Teller's list, enforced or not.
    function tryAllowedAccounts(address teller, address account) internal view returns (bool supported, bool listed) {
        return _tryBool(teller, abi.encodeCall(ITellerAllowlist.allowedAccounts, (account)));
    }

    /// @notice The Teller whose allowlist `queue` applies to its request owners. Zero means the Queue
    ///         checks no allowlist.
    function tryQueueTeller(address queue) internal view returns (bool supported, address teller) {
        (bool ok, uint256 word) = _tryWord(queue, abi.encodeWithSignature("teller()"));
        if (!ok || word > type(uint160).max) return (false, address(0));
        // Bounded above, so the downcast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(word)));
    }

    function _tryBool(address target, bytes memory callData) private view returns (bool supported, bool value) {
        (bool ok, uint256 word) = _tryWord(target, callData);
        if (!ok || word > 1) return (false, false);
        return (true, word == 1);
    }

    function _tryWord(address target, bytes memory callData) private view returns (bool ok, uint256 word) {
        if (target.code.length == 0) return (false, 0);
        (bool success, bytes memory result) = target.staticcall(callData);
        if (!success || result.length != 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }
}
