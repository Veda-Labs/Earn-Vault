// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev The authority a Veda contract asks whether `user` may call `functionSig` on `target`.
interface IAuthority {
    function canCall(address user, address target, bytes4 functionSig) external view returns (bool);
}

/// @dev Ownership and authority surface shared by the BoringVault, its Teller, Queue and stock solver,
///      and the RolesAuthority itself. A call is admitted when the caller is `owner` or `authority`
///      allows it.
interface IAuth {
    function owner() external view returns (address);
    function authority() external view returns (address);
    function setAuthority(address newAuthority) external;
    function transferOwnership(address newOwner) external;
}

/// @dev Veda's RolesAuthority: a user holds roles, and a role holds capabilities on (target, function).
interface IRolesAuthority is IAuthority, IAuth {
    function setUserRole(address user, uint8 role, bool enabled) external;
    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
    function setPublicCapability(address target, bytes4 functionSig, bool enabled) external;
    function doesUserHaveRole(address user, uint8 role) external view returns (bool);
    function doesRoleHaveCapability(uint8 role, address target, bytes4 functionSig) external view returns (bool);
}

/// @dev The BoringVault's custody entry points. Earn never calls them; {VedaRoleGranter} names their
///      selectors so it can refuse to grant a role that reaches custody.
interface IBoringVaultCustody {
    function manage(address target, bytes calldata data, uint256 value) external returns (bytes memory result);
    function manage(address[] calldata targets, bytes[] calldata data, uint256[] calldata values)
        external
        returns (bytes[] memory results);
    function enter(address from, address asset, uint256 assetAmount, address to, uint256 shareAmount) external;
    function exit(address to, address asset, uint256 assetAmount, address from, uint256 shareAmount) external;
    function setBeforeTransferHook(address hook) external;
}
