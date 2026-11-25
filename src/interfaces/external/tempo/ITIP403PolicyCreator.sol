// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev Policy creation on the TIP-403 registry. Anyone may create a policy; `admin` administers it.
interface ITIP403PolicyCreator {
    function createPolicy(address admin, uint8 policyType) external returns (uint64 newPolicyId);
}
