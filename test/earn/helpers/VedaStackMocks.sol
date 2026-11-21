// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Stand-ins for the Tempo precompiles the canonical EarnFactory drives, complete enough for a real
// EarnVault to issue and burn EarnShare through them.
// forge-lint: disable-start(multi-contract-file)
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

/// @dev A TIP-20 EarnShare: role-gated issuance and administration, and an attached transfer policy ID.
contract StackMockShareToken {
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    address private immutable _factory;
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    uint64 public transferPolicyId = 1;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes32 role => mapping(address account => bool held)) private _roles;

    constructor(address admin_) {
        _factory = msg.sender;
        _roles[DEFAULT_ADMIN_ROLE][admin_] = true;
    }

    function setMetadata(string calldata name_, string calldata symbol_) external {
        require(msg.sender == _factory, "NOT_FACTORY");
        name = name_;
        symbol = symbol_;
    }

    function grantRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "NOT_ADMIN");
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "NOT_ADMIN");
        _roles[role][account] = false;
    }

    function hasRole(address account, bytes32 role) external view returns (bool) {
        return _roles[role][account];
    }

    function changeTransferPolicyId(uint64 policyId) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "NOT_ADMIN");
        transferPolicyId = policyId;
    }

    function mint(address to, uint256 amount) external {
        require(_roles[ISSUER_ROLE][msg.sender], "NOT_ISSUER");
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(uint256 amount) external {
        require(_roles[ISSUER_ROLE][msg.sender], "NOT_ISSUER");
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
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

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Deterministic TIP-20 factory: a token lands at `getTokenAddress(sender, salt)`.
contract StackMockTip20Factory {
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata,
        address,
        address admin,
        bytes32 salt
    ) external returns (address token) {
        require(admin == msg.sender, "ADMIN");
        StackMockShareToken share = new StackMockShareToken{ salt: _namespacedSalt(msg.sender, salt) }(admin);
        share.setMetadata(name, symbol);
        return address(share);
    }

    function getTokenAddress(address sender, bytes32 salt) external view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(StackMockShareToken).creationCode, abi.encode(sender)));
        return Create2.computeAddress(_namespacedSalt(sender, salt), initCodeHash);
    }

    function _namespacedSalt(address sender, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(sender, salt));
    }
}

/// @dev TIP-403 registry: anyone creates a policy, and its creator names the administrator. Etched at
///      the precompile address, so it keeps no constructor state.
contract StackMockTip403Registry {
    uint64 private _created;
    mapping(uint64 policyId => bool exists) public policyExists;
    mapping(uint64 policyId => uint8 policyType) private _policyTypes;
    mapping(uint64 policyId => address administrator) private _administrators;

    function createPolicy(address admin, uint8 policyType) external returns (uint64 newPolicyId) {
        // Policy 0 always rejects and policy 1 always allows; created policies start at 2.
        newPolicyId = 2 + _created++;
        policyExists[newPolicyId] = true;
        _policyTypes[newPolicyId] = policyType;
        _administrators[newPolicyId] = admin;
    }

    function policyData(uint64 policyId) external view returns (uint8 policyType, address administrator) {
        return (_policyTypes[policyId], _administrators[policyId]);
    }
}
// forge-lint: disable-end(multi-contract-file)
