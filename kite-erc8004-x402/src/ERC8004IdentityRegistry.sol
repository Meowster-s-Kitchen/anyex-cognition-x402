// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice ERC8004 Identity Registry (practical subset):
/// - ERC721 identity tokens
/// - tokenURI for "agent card" metadata
/// - optional agentWallet binding
contract ERC8004IdentityRegistry is ERC721URIStorage, AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    struct AgentBinding {
        address agentWallet;
    }

    mapping(uint256 => AgentBinding) public binding;
    uint256 public nextId = 1;

    event AgentRegistered(uint256 indexed agentId, address indexed owner, address agentWallet, string uri);
    event AgentWalletUpdated(uint256 indexed agentId, address agentWallet);

    constructor() ERC721("ERC8004 Agent Identity", "AID") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRAR_ROLE, msg.sender);
    }

    function register(
        address owner,
        address agentWallet,
        string calldata uri
    ) external onlyRole(REGISTRAR_ROLE) returns (uint256 agentId) {
        agentId = nextId++;
        _safeMint(owner, agentId);
        _setTokenURI(agentId, uri);
        binding[agentId] = AgentBinding({agentWallet: agentWallet});
        emit AgentRegistered(agentId, owner, agentWallet, uri);
    }

    function setAgentWallet(uint256 agentId, address agentWallet) external {
        require(_isApprovedOrOwner(msg.sender, agentId), "not owner/approved");
        binding[agentId].agentWallet = agentWallet;
        emit AgentWalletUpdated(agentId, agentWallet);
    }
}
