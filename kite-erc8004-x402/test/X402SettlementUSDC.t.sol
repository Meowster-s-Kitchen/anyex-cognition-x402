// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/ERC8004IdentityRegistry.sol";
import "../src/CognitionLicenseSKUs.sol";
import "../src/X402SettlementUSDC.sol";
import "../src/mocks/MockUSDC3009.sol";

contract X402SettlementUSDC_Test is Test {
    // Actors
    uint256 internal payerPk;
    address internal payer;

    uint256 internal sellerPk;
    address internal seller;

    address internal treasury;
    address internal facilitator;

    // Deployed
    ERC8004IdentityRegistry internal identity;
    CognitionLicenseSKUs internal skus;
    MockUSDC3009 internal usdc;
    X402SettlementUSDC internal settle;

    uint256 internal agentId;
    uint256 internal skuCall;
    uint256 internal skuPeriod;

    uint256 internal constant CHAIN_ID = 777777; // pretend Kite chainId
    uint256 internal constant USDC_1 = 1_000_000; // 1 USDC (6 decimals)

    function setUp() public {
        payerPk = 0xA11CE;
        payer = vm.addr(payerPk);

        sellerPk = 0xB0B;
        seller = vm.addr(sellerPk);

        treasury = address(0xTRea5);
        facilitator = address(this); // tests call as FACILITATOR_ROLE holder

        // Deploy mock USDC
        usdc = new MockUSDC3009(CHAIN_ID);
        usdc.mint(payer, 1000 * USDC_1);

        // Deploy registries
        identity = new ERC8004IdentityRegistry();
        skus = new CognitionLicenseSKUs();

        // Register agent identity to seller
        agentId = identity.register(seller, address(0xA6E17), "ipfs://agent-card.json");

        // Create SKUs priced in USDC on Kite
        skuCall = skus.createSKU(agentId, CognitionLicenseSKUs.LicenseType.PER_CALL, address(usdc), 10 * USDC_1, 0);
        skuPeriod = skus.createSKU(agentId, CognitionLicenseSKUs.LicenseType.PER_PERIOD, address(usdc), 50 * USDC_1, 7 days);

        // Deploy settlement (2.5% fee)
        settle = new X402SettlementUSDC(address(identity), address(skus), address(usdc), treasury, 250);

        // Grant facilitator role to test contract is already set in constructor (msg.sender)
        // For completeness, ensure roles exist
        assertTrue(settle.hasRole(settle.FACILITATOR_ROLE(), address(this)));
    }

    function _signAuth(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory sig) {
        bytes32 digest = usdc.computeTransferAuthDigest(from, to, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_settle_per_call_grants_credit_and_accounts_revenue() public {
        // Arrange
        bytes32 paymentId = keccak256("pmt-1");
        uint256 amount = 10 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-1");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        uint256 payerBalBefore = usdc.balanceOf(payer);
        uint256 contractBalBefore = usdc.balanceOf(address(settle));

        // Act
        settle.settleWithUSDC(r, a);

        // Assert funds moved
        assertEq(usdc.balanceOf(payer), payerBalBefore - amount);
        assertEq(usdc.balanceOf(address(settle)), contractBalBefore + amount);

        // Credit granted
        assertEq(settle.callCredits(agentId, payer), 1);
        assertEq(settle.validUntil(agentId, payer), 0);

        // Revenue attribution to current owner (seller)
        uint256 fee = (amount * 250) / 10_000; // 2.5%
        uint256 net = amount - fee;

        assertEq(settle.claimableUSDC(seller), net);
        assertEq(settle.claimableUSDC(treasury), fee);

        // paymentId consumed + nonce used at token layer
        assertTrue(settle.consumedPayment(paymentId));
        assertTrue(usdc.isAuthorizationUsed(payer, nonce));
    }

    function test_settle_per_period_extends_validity() public {
        bytes32 paymentId = keccak256("pmt-2");
        uint256 amount = 50 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-2");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuPeriod,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        uint64 beforeUntil = settle.validUntil(agentId, payer);
        assertEq(beforeUntil, 0);

        settle.settleWithUSDC(r, a);

        uint64 afterUntil = settle.validUntil(agentId, payer);
        assertTrue(afterUntil >= uint64(block.timestamp + 7 days - 2)); // small tolerance
        assertEq(settle.callCredits(agentId, payer), 0);
        assertTrue(settle.hasAccess(agentId, payer));
    }

    function test_replay_paymentId_reverts() public {
        bytes32 paymentId = keccak256("pmt-3");
        uint256 amount = 10 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        // First settlement
        bytes32 nonce1 = keccak256("nonce-3a");
        bytes memory sig1 = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce1);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a1 = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce1,
            signature: sig1
        });

        settle.settleWithUSDC(r, a1);

        // Second attempt with same paymentId but different nonce/signature should revert at settlement layer
        bytes32 nonce2 = keccak256("nonce-3b");
        bytes memory sig2 = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce2);

        X402SettlementUSDC.USDCAuth memory a2 = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce2,
            signature: sig2
        });

        vm.expectRevert("paymentId replay");
        settle.settleWithUSDC(r, a2);
    }

    function test_wrong_amount_reverts() public {
        bytes32 paymentId = keccak256("pmt-4");
        uint256 amount = 9 * USDC_1; // price is 10

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-4");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        vm.expectRevert("amount != price");
        settle.settleWithUSDC(r, a);
    }

    function test_inactive_sku_reverts() public {
        skus.setActive(skuCall, false);

        bytes32 paymentId = keccak256("pmt-5");
        uint256 amount = 10 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-5");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        vm.expectRevert("sku inactive");
        settle.settleWithUSDC(r, a);
    }

    function test_owner_transfer_changes_future_revenue_recipient() public {
        // Transfer identity NFT to newOwner
        address newOwner = address(0xNEW0WNER);

        vm.prank(seller);
        identity.transferFrom(seller, newOwner, agentId);

        // settle per-call once
        bytes32 paymentId = keccak256("pmt-6");
        uint256 amount = 10 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-6");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        settle.settleWithUSDC(r, a);

        uint256 fee = (amount * 250) / 10_000;
        uint256 net = amount - fee;

        // Revenue should accrue to new owner, not original seller
        assertEq(settle.claimableUSDC(seller), 0);
        assertEq(settle.claimableUSDC(newOwner), net);
        assertEq(settle.claimableUSDC(treasury), fee);
    }

    function test_withdraw_works() public {
        // Settle once to accrue to seller
        bytes32 paymentId = keccak256("pmt-7");
        uint256 amount = 10 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-7");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        settle.settleWithUSDC(r, a);

        uint256 fee = (amount * 250) / 10_000;
        uint256 net = amount - fee;

        uint256 sellerBalBefore = usdc.balanceOf(seller);

        vm.prank(seller);
        settle.withdraw(seller, net);

        assertEq(usdc.balanceOf(seller), sellerBalBefore + net);
        assertEq(settle.claimableUSDC(seller), 0);

        // treasury still claimable (not withdrawn)
        assertEq(settle.claimableUSDC(treasury), fee);
    }

    function test_consume_call_decrements_credit() public {
        // Settle per-call once
        bytes32 paymentId = keccak256("pmt-8");
        uint256 amount = 10 * USDC_1;

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-8");
        bytes memory sig = _signAuth(payer, address(settle), amount, validAfter, validBefore, nonce);

        X402SettlementUSDC.Receipt memory r = X402SettlementUSDC.Receipt({
            paymentId: paymentId,
            skuId: skuCall,
            agentId: agentId,
            payer: payer,
            amount: amount
        });

        X402SettlementUSDC.USDCAuth memory a = X402SettlementUSDC.USDCAuth({
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: sig
        });

        settle.settleWithUSDC(r, a);
        assertEq(settle.callCredits(agentId, payer), 1);

        // Facilitator consumes after successful offchain invocation
        settle.consumeCall(agentId, payer);
        assertEq(settle.callCredits(agentId, payer), 0);

        // Now hasAccess false (unless period)
        assertFalse(settle.hasAccess(agentId, payer));
    }
}
