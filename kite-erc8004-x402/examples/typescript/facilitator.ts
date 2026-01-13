import { ethers } from "ethers";
import express from "express";
// Coinbase x402 SDK (example import; adjust to actual package name/version).
import { X402Facilitator, type X402Receipt } from "@coinbase/x402";

type UsdcAuth = {
  validAfter: string;
  validBefore: string;
  nonce: string;
  signature: string;
};

type PaymentIntent = {
  paymentId: string;
  skuId: string;
  agentId: string;
  payer: string;
  amount: string;
  usdcAuth: UsdcAuth;
};

const RPC_URL = process.env.RPC_URL ?? "";
const SETTLEMENT_ADDRESS = process.env.SETTLEMENT_ADDRESS ?? "";
const FACILITATOR_KEY = process.env.FACILITATOR_KEY ?? "";

const settlementAbi = [
  "function settleWithUSDC((bytes32 paymentId,uint256 skuId,uint256 agentId,address payer,uint256 amount),(uint256 validAfter,uint256 validBefore,bytes32 nonce,bytes signature))"
];

const provider = new ethers.JsonRpcProvider(RPC_URL);
const facilitatorWallet = new ethers.Wallet(FACILITATOR_KEY, provider);
const settlement = new ethers.Contract(SETTLEMENT_ADDRESS, settlementAbi, facilitatorWallet);

const isBytes32Hex = (value: string) => /^0x[0-9a-fA-F]{64}$/.test(value);

const normalizePaymentId = (paymentId: string) =>
  isBytes32Hex(paymentId)
    ? paymentId
    : ethers.keccak256(ethers.toUtf8Bytes(paymentId));

const app = express();
app.use(express.json());

const x402 = new X402Facilitator({
  // Coinbase SDK handles x402 intent validation / signature checks.
  // Provide chain / contract config per Coinbase SDK docs.
  chainId: Number(process.env.CHAIN_ID ?? "0")
});

app.post("/x402/settle", async (req, res) => {
  try {
    const intent = req.body as PaymentIntent;

    // 1) Validate intent signature & fields via Coinbase x402 SDK.
    const receipt: X402Receipt = await x402.verifyIntent({
      paymentId: intent.paymentId,
      skuId: intent.skuId,
      agentId: intent.agentId,
      payer: intent.payer,
      amount: intent.amount,
      usdcAuth: intent.usdcAuth
    });
    const normalizedPaymentId = normalizePaymentId(receipt.paymentId);

    // 2) Submit settlement on-chain.
    const tx = await settlement.settleWithUSDC(
      {
        paymentId: normalizedPaymentId,
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

    res.json({ ok: true, txHash: tx.hash });
  } catch (error) {
    res.status(400).json({ ok: false, error: (error as Error).message });
  }
});

app.listen(4000, () => {
  // eslint-disable-next-line no-console
  console.log("Facilitator listening on :4000");
});
