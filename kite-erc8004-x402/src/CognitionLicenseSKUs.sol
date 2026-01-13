// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice License SKUs for "Share" model:
/// PER_CALL => grant N call credits (we grant 1 per receipt in this MVP)
/// PER_PERIOD => grant validity window (extend by periodSeconds)
contract CognitionLicenseSKUs is AccessControl {
    bytes32 public constant SKU_ADMIN_ROLE = keccak256("SKU_ADMIN_ROLE");

    enum LicenseType { PER_CALL, PER_PERIOD }

    struct SKU {
        uint256 agentId;
        LicenseType licenseType;
        address pricingToken;   // informational for UI (USDC on Kite)
        uint256 price;          // informational per receipt
        uint64  periodSeconds;  // only for PER_PERIOD
        bool    active;
    }

    uint256 public nextSkuId = 1;
    mapping(uint256 => SKU) public skus;

    event SKUCreated(
        uint256 indexed skuId,
        uint256 indexed agentId,
        LicenseType licenseType,
        address pricingToken,
        uint256 price,
        uint64 periodSeconds
    );
    event SKUStatus(uint256 indexed skuId, bool active);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SKU_ADMIN_ROLE, msg.sender);
    }

    function createSKU(
        uint256 agentId,
        LicenseType licenseType,
        address pricingToken,
        uint256 price,
        uint64 periodSeconds
    ) external onlyRole(SKU_ADMIN_ROLE) returns (uint256 skuId) {
        require(price > 0, "price=0");
        if (licenseType == LicenseType.PER_PERIOD) require(periodSeconds > 0, "period=0");

        skuId = nextSkuId++;
        skus[skuId] = SKU({
            agentId: agentId,
            licenseType: licenseType,
            pricingToken: pricingToken,
            price: price,
            periodSeconds: periodSeconds,
            active: true
        });

        emit SKUCreated(skuId, agentId, licenseType, pricingToken, price, periodSeconds);
    }

    function setActive(uint256 skuId, bool active) external onlyRole(SKU_ADMIN_ROLE) {
        skus[skuId].active = active;
        emit SKUStatus(skuId, active);
    }
}
