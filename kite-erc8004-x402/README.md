# kite-erc8004-x402

Foundry repo containing:

- ERC8004 identity registry (ERC721 + tokenURI + agent wallet binding)
- License SKU registry (PER_CALL / PER_PERIOD)
- X402-compatible settlement on Kite using USDC (EIP-3009 `transferWithAuthorization`)
- Mock USDC token for local testing

## Architecture overview

```
+--------------------+            +----------------------------+
| Resource Server    |            | Facilitator / Relayer       |
| (API backend)      |            | (x402 verifier)             |
+---------+----------+            +---------------+------------+
          |                                           |
          | 1) client call + payment intent           |
          |------------------------------------------>|
          |                                           |
          | 2) verify x402 intent + build Receipt     |
          |                                           |    +-----------------------+
          |                                           |    | X402SettlementUSDC    |
          |                                           |    | (on Kite)             |
          |                                           |    +-----------+-----------+
          |                                           |                |
          |                                           | 3) settleWithUSDC         |
          |                                           |-------------------------->|
          |                                           | 4) pull USDC via EIP-3009 |
          |                                           | 5) grant entitlement      |
          |                                           | 6) accrue revenue         |
          |                                           |<--------------------------|
          |                                           |
          | 7) allow access (credits/validity)        |
          |<------------------------------------------|
```

### On-chain flow (Kite)

1. **Identity**: The seller (agent owner) mints an ERC8004 identity in `ERC8004IdentityRegistry`.
2. **SKU**: The marketplace or seller creates a SKU in `CognitionLicenseSKUs`.
3. **Payment**: The payer signs a USDC EIP-3009 `transferWithAuthorization` for the SKU price.
4. **Settlement**: A facilitator (trusted relayer) submits `Receipt` + USDC authorization to `X402SettlementUSDC.settleWithUSDC`.
5. **Anti-replay**: The contract marks `paymentId` as consumed. USDC enforces nonce usage at the token layer.
6. **Entitlements**:
   - `PER_CALL`: increments call credits by 1.
   - `PER_PERIOD`: extends `validUntil` by the SKU period.
7. **Revenue**: Settlement accrues net revenue to the **current** identity owner and the marketplace fee to the treasury.
8. **Withdrawal**: Owners and treasury withdraw their `claimableUSDC`.

## Backend endpoint middleware verification

The backend should verify x402 payment intent *before* calling `settleWithUSDC`.
Below is a reference middleware flow for a resource server:

### Inputs expected from client

- `paymentId` (unique per payment attempt)
- `skuId`, `agentId`
- `payer` address
- USDC EIP-3009 authorization:
  - `validAfter`, `validBefore`, `nonce`, `signature`

### Middleware steps (pseudo-code)

```ts
async function x402Middleware(req, res, next) {
  const { paymentId, skuId, agentId, payer, usdcAuth } = req.body;

  // 1) Validate request shape
  assert(paymentId && skuId && agentId && payer && usdcAuth);

  // 2) Fetch SKU and validate pricing
  const sku = await skus.skus(skuId);
  if (!sku.active) throw new Error("sku inactive");
  if (sku.agentId !== agentId) throw new Error("sku/agent mismatch");
  if (sku.pricingToken !== USDC_ADDRESS) throw new Error("not USDC sku");

  // 3) Verify authorization validity window
  const now = Math.floor(Date.now() / 1000);
  if (now <= usdcAuth.validAfter) throw new Error("auth not yet valid");
  if (now >= usdcAuth.validBefore) throw new Error("auth expired");

  // 4) (Optional) Verify EIP-712 signature off-chain
  //     This mirrors MockUSDC3009.computeTransferAuthDigest logic
  //     and ensures the payer signed the authorization.
  const digest = computeTransferAuthDigest({
    from: payer,
    to: SETTLEMENT_ADDRESS,
    value: sku.price,
    validAfter: usdcAuth.validAfter,
    validBefore: usdcAuth.validBefore,
    nonce: usdcAuth.nonce,
    domain: {
      name: "USD Coin",
      version: "2",
      chainId: KITE_CHAIN_ID,
      verifyingContract: USDC_ADDRESS
    }
  });
  const recovered = recoverSigner(digest, usdcAuth.signature);
  if (recovered.toLowerCase() !== payer.toLowerCase()) {
    throw new Error("bad sig");
  }

  // 5) (Optional) Check token-layer nonce usage to fail fast
  const used = await usdc.isAuthorizationUsed(payer, usdcAuth.nonce);
  if (used) throw new Error("auth already used");

  // 6) Submit on-chain settlement
  await settlement.settleWithUSDC(
    { paymentId, skuId, agentId, payer, amount: sku.price },
    usdcAuth
  );

  // 7) Allow request to proceed after settlement success
  next();
}
```

### Notes

- The settlement contract **re-checks** SKU, amount, and `paymentId` anti-replay.
- USDC itself enforces authorization nonce usage, providing a second anti-replay layer.
- The middleware only needs to call `settleWithUSDC` once, then grant access or consume credits.
- For *PER_CALL* SKUs, your resource server should decrement credits via `consumeCall` after successful off-chain usage.

## Development

Install dependencies:

```
forge install OpenZeppelin/openzeppelin-contracts
```

Run tests:

```
forge test -vv
```

## Deployment

### Networks

- **ETH Mainnet**
- **BSC Mainnet**
- **Kite Testnet** (Chain name: KiteAI Testnet, RPC: <https://rpc-testnet.gokite.ai/>, Chain ID: 2368, Token: KITE, Explorer: <https://testnet.kitescan.ai/>)

### Environment variables

Set these before running `forge script`:

- `PRIVATE_KEY`: Deployer key (hex, no `0x` prefix recommended).
- `RPC_URL`: The target chain RPC URL (e.g., mainnet, BSC, or Kite testnet).
- `TREASURY_ADDRESS`: (Optional) Marketplace fee treasury. Defaults to the deployer.
- `FEE_BPS`: (Optional) Marketplace fee in basis points (0-2000). Defaults to `0`.
- `USDC_ADDRESS`: (Required for Kite Testnet and any unknown chain). See script mapping notes below.

### USDC constructor args per network

`X402SettlementUSDC` requires a USDC address. The deployment script includes a chain ID switch:

- **ETH Mainnet (1):** `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- **BSC Mainnet (56):** `0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d`
- **Kite Testnet (2368):** Set `USDC_ADDRESS` in your environment.

If you need to change these addresses or add networks, edit `_usdcForChain` in `script/Deploy.s.sol`.

### Example commands

```bash
# ETH Mainnet
export RPC_URL=<your-mainnet-rpc>
export PRIVATE_KEY=<your-private-key>
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify -vvvv

# BSC Mainnet
export RPC_URL=<your-bsc-rpc>
export PRIVATE_KEY=<your-private-key>
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify -vvvv

# Kite Testnet
export RPC_URL=https://rpc-testnet.gokite.ai/
export PRIVATE_KEY=<your-private-key>
export USDC_ADDRESS=<kite-testnet-usdc-address>
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify -vvvv
```
