// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {
    IAccountant,
    IStepAccountant,
    IYieldStreamingAccountant
} from "../../../../interfaces/external/veda/IAccountant.sol";

/// @notice Reads when a Veda Accountant last reported its rate, the same way `VedaEngine` does.
/// @dev YieldStreaming exposes a dedicated strategist timestamp; step accounting exposes the rate update
///      in its canonical AccountantState tuple. Any other freshness ABI is unsupported. Unlike
///      `VedaEngine`, which reverts on an answer it cannot decode, this library reports it as
///      unsupported, so a caller can choose between failing closed and deferring.
library VedaAccountantFreshness {
    /// @return supported Whether the Accountant exposes a freshness ABI this library reads.
    /// @return updatedAt The Accountant's last rate report, meaningful only when `supported`.
    function tryRateUpdatedAt(IAccountant accountant) internal view returns (bool supported, uint64 updatedAt) {
        (bool success, bytes memory result) = address(accountant)
            .staticcall(abi.encodeWithSelector(IYieldStreamingAccountant.lastStrategistUpdateTimestamp.selector));
        if (success && result.length == 32) {
            uint256 timestamp = abi.decode(result, (uint256));
            if (timestamp > type(uint64).max) return (false, 0);
            // Bounded above, so the downcast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (true, uint64(timestamp));
        }

        (success, result) =
            address(accountant).staticcall(abi.encodeWithSelector(IStepAccountant.accountantState.selector));
        if (!success || result.length != 12 * 32) return (false, 0);

        // AccountantState, field for field: address, uint96, uint128, uint128, uint96, uint16, uint16,
        // uint64, bool, uint24, uint16, uint16. Every word must be a well-formed value of its field, as
        // a typed decode of the whole tuple requires; the eighth is `lastUpdateTimestamp`.
        uint8[12] memory fieldBits = [160, 96, 128, 128, 96, 16, 16, 64, 1, 24, 16, 16];
        uint256 lastUpdateTimestamp;
        for (uint256 i = 0; i < 12; i++) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(result, 0x20), mul(i, 0x20)))
            }
            if (word >> fieldBits[i] != 0) return (false, 0);
            if (i == 7) lastUpdateTimestamp = word;
        }
        // Bounded to 64 bits above, so the downcast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, uint64(lastUpdateTimestamp));
    }
}
