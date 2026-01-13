import { ethers } from "ethers";

type UsdcAuth = {
  validAfter: bigint;
  validBefore: bigint;
  nonce: string; // bytes32 hex
  signature: string;
};

type VerifiedSku = {
  skuId: bigint;
  agentId: bigint;
  licenseType: number;
  pricingToken: string;
  price: bigint;
  periodSeconds: bigint;
};

const RPC_URL = process.env.RPC_URL ?? "";
const SKU_REGISTRY = process.env.SKU_REGISTRY ?? "";
const USDC_ADDRESS = process.env.USDC_ADDRESS ?? "";
const SETTLEMENT_ADDRESS = process.env.SETTLEMENT_ADDRESS ?? "";
const CHAIN_ID = BigInt(process.env.CHAIN_ID ?? "0");

const USDC_NAME = "USD Coin";
const USDC_VERSION = "2";

const skuAbi = [
  "function skus(uint256 skuId) view returns (uint256 agentId, uint8 licenseType, address pricingToken, uint256 price, uint64 periodSeconds, bool active)"
];

const addressRegex = /^0x[a-fA-F0-9]{40}$/;
const missingVars = ["RPC_URL", "SKU_REGISTRY", "USDC_ADDRESS", "SETTLEMENT_ADDRESS"].filter(
  (key) => !process.env[key]?.trim()
);
const invalidAddressVars = [
  { key: "SKU_REGISTRY", value: SKU_REGISTRY },
  { key: "USDC_ADDRESS", value: USDC_ADDRESS },
  { key: "SETTLEMENT_ADDRESS", value: SETTLEMENT_ADDRESS }
].filter((entry) => !addressRegex.test(entry.value));
const invalidChainId = CHAIN_ID <= 0n;

if (missingVars.length > 0 || invalidAddressVars.length > 0 || invalidChainId) {
  const messages: string[] = [];
  if (missingVars.length > 0) {
    messages.push(`Missing required environment variables: ${missingVars.join(", ")}`);
  }
  if (invalidAddressVars.length > 0) {
    messages.push(
      `Invalid address values (expected 0x + 40 hex): ${invalidAddressVars
        .map((entry) => entry.key)
        .join(", ")}`
    );
  }
  if (invalidChainId) {
    messages.push("Invalid CHAIN_ID (must be > 0).");
  }
  throw new Error(messages.join(" "));
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const skuContract = new ethers.Contract(SKU_REGISTRY, skuAbi, provider);

const isBytes32Hex = (value: string) => /^0x[0-9a-fA-F]{64}$/.test(value);

const normalizePaymentId = (paymentId: string) =>
  isBytes32Hex(paymentId)
    ? paymentId
    : ethers.keccak256(ethers.toUtf8Bytes(paymentId));

export async function verifySku(params: {
  skuId: bigint;
  agentId: bigint;
}): Promise<VerifiedSku> {
  const { skuId, agentId } = params;
  const [
    skuAgentId,
    licenseType,
    pricingToken,
    price,
    periodSeconds,
    active
  ] = await skuContract.skus(skuId);

  if (!active) {
    throw new Error("sku inactive");
  }
  if (skuAgentId !== agentId) {
    throw new Error("sku/agent mismatch");
  }
  if (pricingToken.toLowerCase() !== USDC_ADDRESS.toLowerCase()) {
    throw new Error("not USDC sku");
  }

  return {
    skuId,
    agentId,
    licenseType,
    pricingToken,
    price,
    periodSeconds
  };
}

export async function buildUsdcAuthorization(params: {
  payerPrivateKey: string;
  amount: bigint;
  validAfter: bigint;
  validBefore: bigint;
  nonce: string; // bytes32 hex
}): Promise<{ payer: string; usdcAuth: UsdcAuth }> {
  const { payerPrivateKey, amount, validAfter, validBefore, nonce } = params;
  const wallet = new ethers.Wallet(payerPrivateKey);

  const domain = {
    name: USDC_NAME,
    version: USDC_VERSION,
    chainId: CHAIN_ID,
    verifyingContract: USDC_ADDRESS
  };

  const types = {
    TransferWithAuthorization: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "validAfter", type: "uint256" },
      { name: "validBefore", type: "uint256" },
      { name: "nonce", type: "bytes32" }
    ]
  };

  const value = {
    from: wallet.address,
    to: SETTLEMENT_ADDRESS,
    value: amount,
    validAfter,
    validBefore,
    nonce
  };

  const signature = await wallet.signTypedData(domain, types, value);

  return {
    payer: wallet.address,
    usdcAuth: {
      validAfter,
      validBefore,
      nonce,
      signature
    }
  };
}

export async function buildPaymentIntent(params: {
  paymentId: string;
  skuId: bigint;
  agentId: bigint;
  payerPrivateKey: string;
  validAfter: bigint;
  validBefore: bigint;
  nonce: string;
}) {
  const { paymentId, skuId, agentId, payerPrivateKey, validAfter, validBefore, nonce } = params;
  const sku = await verifySku({ skuId, agentId });
  const { payer, usdcAuth } = await buildUsdcAuthorization({
    payerPrivateKey,
    amount: sku.price,
    validAfter,
    validBefore,
    nonce
  });
  const normalizedPaymentId = normalizePaymentId(paymentId);

  return {
    paymentId: normalizedPaymentId,
    skuId,
    agentId,
    payer,
    amount: sku.price,
    usdcAuth
  };
}

export async function submitToFacilitator(intent: {
  paymentId: string;
  skuId: bigint;
  agentId: bigint;
  payer: string;
  amount: bigint;
  usdcAuth: UsdcAuth;
}) {
  const response = await fetch("https://facilitator.example.com/x402/settle", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      paymentId: intent.paymentId,
      skuId: intent.skuId.toString(),
      agentId: intent.agentId.toString(),
      payer: intent.payer,
      amount: intent.amount.toString(),
      usdcAuth: {
        validAfter: intent.usdcAuth.validAfter.toString(),
        validBefore: intent.usdcAuth.validBefore.toString(),
        nonce: intent.usdcAuth.nonce,
        signature: intent.usdcAuth.signature
      }
    })
  });

  if (!response.ok) {
    throw new Error(`facilitator error: ${response.status}`);
  }

  return response.json();
}
