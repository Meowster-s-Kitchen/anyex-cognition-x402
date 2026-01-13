// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface ISKUs {
    enum LicenseType { PER_CALL, PER_PERIOD }
    function skus(uint256 skuId) external view returns (
        uint256 agentId,
        LicenseType licenseType,
        address pricingToken,
        uint256 price,
        uint64  periodSeconds,
        bool    active
    );
}

interface IERC3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    function isAuthorizationUsed(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @notice Kite Mainnet canonical settlement:
/// - Facilitator submits receipt + USDC authorization (EIP-3009)
/// - Contract pulls funds into itself and accrues claimable balances
/// - Anchors payment receipt (paymentId) to prevent replay
/// - Grants access entitlements: PER_CALL credits or PER_PERIOD validity
contract X402SettlementUSDC is AccessControl {
    bytes32 public constant FACILITATOR_ROLE = keccak256("FACILITATOR_ROLE");

    IERC721Owner public immutable identity;
    ISKUs public immutable skuRegistry;
    IERC3009 public immutable usdc;

    uint16 public marketplaceFeeBps; // 0..10000
    address public feeTreasury;

    // paymentId anti-replay
    mapping(bytes32 => bool) public consumedPayment;

    // entitlements
    mapping(uint256 => mapping(address => uint256)) public callCredits; // agentId => payer => credits
    mapping(uint256 => mapping(address => uint64))  public validUntil;  // agentId => payer => timestamp

    // accounting in USDC units (6 decimals)
    mapping(address => uint256) public claimableUSDC;

    event ReceiptAnchored(bytes32 indexed paymentId, uint256 indexed agentId, uint256 indexed skuId, address payer, uint256 amount);
    event EntitlementGranted(uint256 indexed agentId, uint256 indexed skuId, address indexed payer, uint256 callsAdded, uint64 newValidUntil);
    event RevenueAccrued(address indexed owner, uint256 netAmount, uint256 feeAmount);
    event Withdrawn(address indexed to, uint256 amount);

    struct Receipt {
        bytes32 paymentId; // unique per settlement attempt
        uint256 skuId;
        uint256 agentId;
        address payer;
        uint256 amount;    // USDC amount
    }

    struct USDCAuth {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        bytes signature; // EIP-712 sig by payer
    }

    constructor(
        address identityRegistry,
        address skuRegistry_,
        address usdc_,
        address treasury,
        uint16 feeBps
    ) {
        require(feeBps <= 2000, "fee too high"); // guardrail 20%
        identity = IERC721Owner(identityRegistry);
        skuRegistry = ISKUs(skuRegistry_);
        usdc = IERC3009(usdc_);
        feeTreasury = treasury;
        marketplaceFeeBps = feeBps;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FACILITATOR_ROLE, msg.sender);
    }

    function setTreasury(address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeTreasury = treasury;
    }

    function setFeeBps(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(feeBps <= 2000, "fee too high");
        marketplaceFeeBps = feeBps;
    }

    /// @notice Facilitator calls this with x402-verified payment intent (authorization) to settle on Kite.
    /// Pulls USDC from payer using ERC-3009 transferWithAuthorization.
    function settleWithUSDC(Receipt calldata r, USDCAuth calldata a) external onlyRole(FACILITATOR_ROLE) {
        require(!consumedPayment[r.paymentId], "paymentId replay");
        consumedPayment[r.paymentId] = true;

        // validate SKU
        (uint256 skuAgentId, ISKUs.LicenseType lt, address pricingToken, uint256 price, uint64 periodSeconds, bool active) =
            skuRegistry.skus(r.skuId);

        require(active, "sku inactive");
        require(skuAgentId == r.agentId, "sku/agent mismatch");
        require(pricingToken == address(usdc), "not USDC sku");
        require(r.amount == price, "amount != price");
        require(r.payer != address(0), "payer=0");

        // Pull funds into this contract using ERC-3009 (no approve)
        // NOTE: USDCAuth nonce will also prevent replay at token layer
        usdc.transferWithAuthorization(
            r.payer,
            address(this),
            r.amount,
            a.validAfter,
            a.validBefore,
            a.nonce,
            a.signature
        );

        // grant entitlement
        if (lt == ISKUs.LicenseType.PER_CALL) {
            callCredits[r.agentId][r.payer] += 1;
            emit EntitlementGranted(r.agentId, r.skuId, r.payer, 1, validUntil[r.agentId][r.payer]);
        } else {
            uint64 current = validUntil[r.agentId][r.payer];
            uint64 base = current > uint64(block.timestamp) ? current : uint64(block.timestamp);
            uint64 next = base + periodSeconds;
            validUntil[r.agentId][r.payer] = next;
            emit EntitlementGranted(r.agentId, r.skuId, r.payer, 0, next);
        }

        // revenue attribution to CURRENT owner
        address owner = identity.ownerOf(r.agentId);
        uint256 fee = (r.amount * marketplaceFeeBps) / 10_000;
        uint256 net = r.amount - fee;

        claimableUSDC[owner] += net;
        claimableUSDC[feeTreasury] += fee;

        emit ReceiptAnchored(r.paymentId, r.agentId, r.skuId, r.payer, r.amount);
        emit RevenueAccrued(owner, net, fee);
    }

    function hasAccess(uint256 agentId, address caller) external view returns (bool) {
        if (callCredits[agentId][caller] > 0) return true;
        if (validUntil[agentId][caller] >= uint64(block.timestamp)) return true;
        return false;
    }

    /// @notice Optional metering hook; should be called by your resource server's trusted relayer.
    function consumeCall(uint256 agentId, address caller) external onlyRole(FACILITATOR_ROLE) {
        require(callCredits[agentId][caller] > 0, "no credits");
        callCredits[agentId][caller] -= 1;
    }

    /// @notice Withdraw accrued USDC.
    function withdraw(address to, uint256 amount) external {
        require(amount > 0, "amount=0");
        uint256 bal = claimableUSDC[msg.sender];
        require(bal >= amount, "insufficient claimable");
        claimableUSDC[msg.sender] = bal - amount;

        // Transfer out of this contract: since MockUSDC uses transfer(), we can call it via low-level
        (bool ok, ) = address(usdc).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");

        emit Withdrawn(to, amount);
    }
}
