import { ethers } from "ethers";
import { buildPaymentIntent } from "./resource-server";

type FacilitatorResponse = {
  ok: boolean;
  txHash?: string;
  error?: string;
};

const requiredEnvVars = [
  "RPC_URL",
  "IDENTITY_REGISTRY",
  "REGISTRAR_KEY",
  "AGENT_OWNER_KEY",
  "SKU_ID",
  "SKU_REGISTRY",
  "USDC_ADDRESS",
  "SETTLEMENT_ADDRESS",
  "CHAIN_ID",
  "PAYER_KEY",
  "FACILITATOR_URL"
];

const missingEnvVars = requiredEnvVars.filter((key) => !process.env[key]?.trim());

if (missingEnvVars.length > 0) {
  throw new Error(`Missing required environment variables: ${missingEnvVars.join(", ")}`);
}

const identityAbi = [
  "function register(address owner, address agentWallet, string uri) returns (uint256)",
  "function REGISTRAR_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)"
];

const toBigIntEnv = (value: string | undefined, fallback: bigint) => {
  if (!value?.trim()) {
    return fallback;
  }
  const parsed = BigInt(value);
  if (parsed < 0n) {
    throw new Error(`Invalid negative value: ${value}`);
  }
  return parsed;
};

async function submitToFacilitator(intent: {
  paymentId: string;
  skuId: bigint;
  agentId: bigint;
  payer: string;
  amount: bigint;
  usdcAuth: {
    validAfter: bigint;
    validBefore: bigint;
    nonce: string;
    signature: string;
  };
}): Promise<FacilitatorResponse> {
  const response = await fetch(process.env.FACILITATOR_URL ?? "", {
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
    throw new Error(`Facilitator error (${response.status}): ${await response.text()}`);
  }

  return response.json();
}

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL ?? "");
  const registrar = new ethers.Wallet(process.env.REGISTRAR_KEY ?? "", provider);
  const identity = new ethers.Contract(
    process.env.IDENTITY_REGISTRY ?? "",
    identityAbi,
    registrar
  );

  const registrarRole = await identity.REGISTRAR_ROLE();
  const hasRole = await identity.hasRole(registrarRole, registrar.address);

  if (!hasRole) {
    throw new Error(`Registrar ${registrar.address} missing REGISTRAR_ROLE on identity registry.`);
  }

  const ownerWallet = new ethers.Wallet(process.env.AGENT_OWNER_KEY ?? "");
  const ownerAddress = ownerWallet.address;
  const agentWallet = process.env.AGENT_WALLET?.trim() || ownerAddress;
  const agentUri = process.env.AGENT_URI?.trim() || "ipfs://agent-card";

  const registeredAgentId = await identity.register.staticCall(
    ownerAddress,
    agentWallet,
    agentUri
  );

  const registerTx = await identity.register(ownerAddress, agentWallet, agentUri);
  await registerTx.wait();

  const agentId = BigInt(process.env.AGENT_ID ?? registeredAgentId.toString());
  const skuId = BigInt(process.env.SKU_ID ?? "0");

  const now = BigInt(Math.floor(Date.now() / 1000));
  const validAfter = toBigIntEnv(process.env.USDC_VALID_AFTER, now - 60n);
  const validBefore = toBigIntEnv(process.env.USDC_VALID_BEFORE, now + 3600n);
  const nonce =
    process.env.USDC_NONCE?.trim() || ethers.hexlify(ethers.randomBytes(32));
  const paymentId = process.env.PAYMENT_ID?.trim() || `e2e-${Date.now()}`;

  const intent = await buildPaymentIntent({
    paymentId,
    skuId,
    agentId,
    payerPrivateKey: process.env.PAYER_KEY ?? "",
    validAfter,
    validBefore,
    nonce
  });

  const facilitatorResponse = await submitToFacilitator(intent);

  // eslint-disable-next-line no-console
  console.log("Facilitator settlement response:", facilitatorResponse);

  const resourceResponse = {
    ok: true,
    data: {
      message: "Resource unlocked",
      paymentId: intent.paymentId,
      skuId: intent.skuId.toString(),
      agentId: intent.agentId.toString()
    }
  };

  // eslint-disable-next-line no-console
  console.log("Mock resource response:", resourceResponse);
}

main().catch((error) => {
  // eslint-disable-next-line no-console
  console.error(error);
  process.exit(1);
});
