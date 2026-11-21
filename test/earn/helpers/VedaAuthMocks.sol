// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Stand-ins for a Veda deployment's authority surface, written against its public interfaces because
// Veda's source is not vendored here. Every gated function asks its own `authority`, as the real
// contracts do, so a test can prove which caller reaches which function.
// forge-lint: disable-start(multi-contract-file,unsafe-typecast,unused-return,erc20-unchecked-transfer)
import { IAuthority } from "../../../src/interfaces/external/veda/IRolesAuthority.sol";
import { OnChainWithdraw } from "../../../src/interfaces/external/veda/VedaTypes.sol";
import { IERC20T } from "./VedaEngineMocks.sol";

/// @dev Owner-or-authority gate: a call passes when the caller is `owner` or `authority` allows it.
abstract contract MockAuth {
    address public owner;
    address public authority;

    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event AuthorityUpdated(address indexed user, address indexed newAuthority);

    constructor(address owner_, address authority_) {
        owner = owner_;
        authority = authority_;
    }

    modifier requiresAuth() {
        require(isAuthorized(msg.sender, msg.sig), "UNAUTHORIZED");
        _;
    }

    function isAuthorized(address user, bytes4 functionSig) internal view returns (bool) {
        address auth = authority;
        return (auth != address(0) && IAuthority(auth).canCall(user, address(this), functionSig)) || user == owner;
    }

    function setAuthority(address newAuthority) public {
        // The owner is checked first so a broken authority can always be replaced by the owner.
        require(msg.sender == owner || IAuthority(authority).canCall(msg.sender, address(this), msg.sig));
        authority = newAuthority;
        emit AuthorityUpdated(msg.sender, newAuthority);
    }

    function transferOwnership(address newOwner) public requiresAuth {
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }
}

/// @dev Role table: a user holds roles, a role holds capabilities on (target, function), and a
///      capability may be public. Every setter is gated like any other function.
contract MockRolesAuthority is MockAuth {
    mapping(address => bytes32) public getUserRoles;
    mapping(address => mapping(bytes4 => bool)) public isCapabilityPublic;
    mapping(address => mapping(bytes4 => bytes32)) public getRolesWithCapability;

    constructor(address owner_, address authority_) MockAuth(owner_, authority_) { }

    function doesUserHaveRole(address user, uint8 role) public view returns (bool) {
        return (uint256(getUserRoles[user]) >> role) & 1 != 0;
    }

    function doesRoleHaveCapability(uint8 role, address target, bytes4 functionSig) public view returns (bool) {
        return (uint256(getRolesWithCapability[target][functionSig]) >> role) & 1 != 0;
    }

    function canCall(address user, address target, bytes4 functionSig) public view returns (bool) {
        return isCapabilityPublic[target][functionSig]
            || bytes32(0) != getUserRoles[user] & getRolesWithCapability[target][functionSig];
    }

    function setPublicCapability(address target, bytes4 functionSig, bool enabled) public requiresAuth {
        isCapabilityPublic[target][functionSig] = enabled;
    }

    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) public requiresAuth {
        if (enabled) getRolesWithCapability[target][functionSig] |= bytes32(1 << role);
        else getRolesWithCapability[target][functionSig] &= ~bytes32(1 << role);
    }

    function setUserRole(address user, uint8 role, bool enabled) public requiresAuth {
        if (enabled) getUserRoles[user] |= bytes32(1 << role);
        else getUserRoles[user] &= ~bytes32(1 << role);
    }
}

/// @dev BoringVault shares and asset custody. `enter`, `exit` and `manage` are the custody functions.
contract AuthedBoringVault is MockAuth {
    uint8 public immutable decimals;
    uint256 public totalSupply;
    address public hook;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address owner_, address authority_, uint8 decimals_) MockAuth(owner_, authority_) {
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function enter(address from, address asset, uint256 assetAmount, address to, uint256 shareAmount)
        external
        requiresAuth
    {
        if (assetAmount != 0) require(IERC20T(asset).transferFrom(from, address(this), assetAmount), "ENTER");
        balanceOf[to] += shareAmount;
        totalSupply += shareAmount;
    }

    function exit(address to, address asset, uint256 assetAmount, address from, uint256 shareAmount)
        external
        requiresAuth
    {
        require(balanceOf[from] >= shareAmount, "SHARES");
        balanceOf[from] -= shareAmount;
        totalSupply -= shareAmount;
        if (assetAmount != 0) require(IERC20T(asset).transfer(to, assetAmount), "EXIT");
    }

    function manage(address target, bytes calldata data, uint256 value)
        external
        requiresAuth
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call{ value: value }(data);
        require(success, "MANAGE");
    }

    function manage(address[] calldata targets, bytes[] calldata data, uint256[] calldata values)
        external
        requiresAuth
        returns (bytes[] memory results)
    {
        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            bool success;
            (success, results[i]) = targets[i].call{ value: values[i] }(data[i]);
            require(success, "MANAGE");
        }
    }

    function setBeforeTransferHook(address hook_) external requiresAuth {
        hook = hook_;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IRateSource {
    function getRateInQuoteSafe(address quote) external view returns (uint256);
}

/// @dev Teller whose bulk paths are gated and move assets through the vault's gated enter and exit.
contract AuthedTeller is MockAuth {
    AuthedBoringVault public immutable vault;
    address public immutable accountant;
    uint256 public bulkDepositCalls;
    uint256 public bulkWithdrawCalls;

    constructor(address owner_, address authority_, AuthedBoringVault vault_, address accountant_)
        MockAuth(owner_, authority_)
    {
        vault = vault_;
        accountant = accountant_;
    }

    function bulkDeposit(address depositAsset, uint256 depositAmount, uint256 minimumMint, address to)
        external
        requiresAuth
        returns (uint256 shares)
    {
        bulkDepositCalls++;
        shares = depositAmount * (10 ** uint256(vault.decimals()))
            / IRateSource(accountant).getRateInQuoteSafe(depositAsset);
        require(shares >= minimumMint, "MIN_MINT");
        vault.enter(msg.sender, depositAsset, depositAmount, to, shares);
    }

    function bulkWithdraw(address withdrawAsset, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        requiresAuth
        returns (uint256 assetsOut)
    {
        bulkWithdrawCalls++;
        assetsOut =
            shareAmount * IRateSource(accountant).getRateInQuoteSafe(withdrawAsset) / (10 ** uint256(vault.decimals()));
        require(assetsOut >= minimumAssets, "MIN_ASSETS");
        vault.exit(to, withdrawAsset, assetsOut, msg.sender, shareAmount);
    }
}

interface ISolveCallback {
    function boringSolve(
        address initiator,
        address boringVault,
        address solveAsset,
        uint256 totalShares,
        uint256 requiredAssets,
        bytes calldata solveData
    ) external;
}

/// @dev Tracking Queue: gated request, ID-based cancellation and solve; requests stay readable by ID.
contract AuthedQueue is MockAuth {
    AuthedBoringVault public immutable boringVault;
    address public immutable accountant;
    uint96 public nonce = 1;
    bool public trackWithdrawsOnChain = true;
    mapping(bytes32 => OnChainWithdraw) internal _requests;
    mapping(bytes32 => bool) public isActive;

    constructor(address owner_, address authority_, AuthedBoringVault vault_, address accountant_)
        MockAuth(owner_, authority_)
    {
        boringVault = vault_;
        accountant = accountant_;
    }

    function requestOnChainWithdraw(address assetOut, uint128 shares, uint16 discount, uint24 secondsToDeadline)
        external
        requiresAuth
        returns (bytes32 requestId)
    {
        require(boringVault.transferFrom(msg.sender, address(this), shares), "PULL");
        OnChainWithdraw memory request = OnChainWithdraw({
            nonce: nonce++,
            user: msg.sender,
            assetOut: assetOut,
            amountOfShares: shares,
            amountOfAssets: previewAssetsOut(assetOut, shares, discount),
            creationTime: uint40(block.timestamp),
            secondsToMaturity: 0,
            secondsToDeadline: secondsToDeadline
        });
        requestId = keccak256(abi.encode(request));
        _requests[requestId] = request;
        isActive[requestId] = true;
    }

    function cancelOnChainWithdrawUsingRequestId(bytes32 requestId)
        external
        requiresAuth
        returns (OnChainWithdraw memory request)
    {
        request = getOnChainWithdraw(requestId);
        require(isActive[requestId], "REQUEST");
        require(request.user == msg.sender, "USER");
        isActive[requestId] = false;
        require(boringVault.transfer(request.user, request.amountOfShares), "RETURN");
    }

    /// @dev The stock solve: hand the shares to the solver, let it raise the assets, then pay each user.
    function solveOnChainWithdraws(OnChainWithdraw[] calldata requests, bytes calldata solveData, address solver)
        external
        requiresAuth
    {
        address solveAsset = requests[0].assetOut;
        uint256 totalShares;
        uint256 requiredAssets;
        for (uint256 i = 0; i < requests.length; i++) {
            bytes32 requestId = keccak256(abi.encode(requests[i]));
            require(isActive[requestId], "REQUEST");
            require(requests[i].assetOut == solveAsset, "ASSET");
            isActive[requestId] = false;
            totalShares += requests[i].amountOfShares;
            requiredAssets += requests[i].amountOfAssets;
        }
        require(boringVault.transfer(solver, totalShares), "SHARES");
        ISolveCallback(solver)
            .boringSolve(msg.sender, address(boringVault), solveAsset, totalShares, requiredAssets, solveData);
        for (uint256 i = 0; i < requests.length; i++) {
            require(IERC20T(solveAsset).transferFrom(solver, requests[i].user, requests[i].amountOfAssets), "PAY");
        }
    }

    function previewAssetsOut(address assetOut, uint128 shares, uint16 discount) public view returns (uint128) {
        uint256 discountedRate = IRateSource(accountant).getRateInQuoteSafe(assetOut) * (10_000 - discount) / 10_000;
        return uint128(uint256(shares) * discountedRate / (10 ** uint256(boringVault.decimals())));
    }

    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }

    function getOnChainWithdraw(bytes32 requestId) public view returns (OnChainWithdraw memory request) {
        request = _requests[requestId];
        require(request.nonce != 0, "REQUEST");
    }
}

interface IBulkWithdraw {
    function bulkWithdraw(address withdrawAsset, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut);
}

/// @dev Stock solver fixed to one Queue: a gated redeem solve that the Queue calls back into.
contract AuthedSolver is MockAuth {
    AuthedQueue public immutable queue;

    constructor(address owner_, address authority_, AuthedQueue queue_) MockAuth(owner_, authority_) {
        queue = queue_;
    }

    function boringRedeemSolve(OnChainWithdraw[] calldata requests, address teller, bool coverDeficit)
        external
        requiresAuth
    {
        queue.solveOnChainWithdraws(requests, abi.encode(msg.sender, teller, coverDeficit), address(this));
    }

    function boringSolve(
        address initiator,
        address boringVault,
        address solveAsset,
        uint256 totalShares,
        uint256 requiredAssets,
        bytes calldata solveData
    ) external requiresAuth {
        require(msg.sender == address(queue) && initiator == address(this), "SOLVE");
        (address solverOrigin, address teller, bool coverDeficit) = abi.decode(solveData, (address, address, bool));
        uint256 assetsOut = IBulkWithdraw(teller).bulkWithdraw(solveAsset, totalShares, 0, address(this));
        if (assetsOut < requiredAssets) {
            require(coverDeficit, "DEFICIT");
            require(IERC20T(solveAsset).transferFrom(solverOrigin, address(this), requiredAssets - assetsOut), "COVER");
        } else if (assetsOut > requiredAssets) {
            require(IERC20T(solveAsset).transfer(boringVault, assetsOut - requiredAssets), "SURPLUS");
        }
        require(IERC20T(solveAsset).approve(address(queue), requiredAssets), "APPROVE");
    }
}
// forge-lint: disable-end(multi-contract-file,unsafe-typecast,unused-return,erc20-unchecked-transfer)
