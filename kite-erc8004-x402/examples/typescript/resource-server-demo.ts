import { ethers } from "ethers";
import express from "express";
import type { X402Receipt } from "@coinbase/x402";
import { x402SkuMiddleware } from "./facilitator-middleware";

type LocalsWithReceipt = {
  x402: {
    receipt: X402Receipt;
  };
};

const requiredEnvVars = [
  "RPC_URL",
  "SETTLEMENT_ADDRESS",
  "FACILITATOR_KEY",
  "CHAIN_ID"
];

const missingEnvVars = requiredEnvVars.filter((key) => !process.env[key]?.trim());

if (missingEnvVars.length > 0) {
  throw new Error(`Missing required environment variables: ${missingEnvVars.join(", ")}`);
}

const chainIdNumber = Number(process.env.CHAIN_ID ?? "0");
if (!Number.isInteger(chainIdNumber) || chainIdNumber <= 0) {
  throw new Error("Invalid CHAIN_ID (must be a positive integer).");
}

const settlementAbi = [
  "function settleWithUSDC((bytes32 paymentId,uint256 skuId,uint256 agentId,address payer,uint256 amount),(uint256 validAfter,uint256 validBefore,bytes32 nonce,bytes signature))"
];

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL ?? "");
const facilitatorWallet = new ethers.Wallet(process.env.FACILITATOR_KEY ?? "", provider);
const settlement = new ethers.Contract(
  process.env.SETTLEMENT_ADDRESS ?? "",
  settlementAbi,
  facilitatorWallet
);

const app = express();
app.use(express.json());

app.post("/resource", x402SkuMiddleware, async (req, res) => {
  try {
    const { receipt } = (res.locals as LocalsWithReceipt).x402;
    const tx = await settlement.settleWithUSDC(
      {
        paymentId: receipt.paymentId,
        skuId: receipt.skuId,
        agentId: receipt.agentId,
        payer: receipt.payer,
        amount: receipt.amount
      },
      {
        validAfter: receipt.usdcAuth.validAfter,
        validBefore: receipt.usdcAuth.validBefore,
        nonce: receipt.usdcAuth.nonce,
        signature: receipt.usdcAuth.signature
      }
    );

    await tx.wait();

    res.json({
      ok: true,
      txHash: tx.hash,
      data: {
        message: "Resource delivered",
        paymentId: receipt.paymentId,
        skuId: receipt.skuId,
        agentId: receipt.agentId
      }
    });
  } catch (error) {
    res.status(400).json({ ok: false, error: (error as Error).message });
  }
});

app.listen(5000, () => {
  // eslint-disable-next-line no-console
  console.log("Resource server demo listening on :5000");
});
