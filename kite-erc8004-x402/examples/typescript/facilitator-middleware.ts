import type { NextFunction, Request, Response } from "express";
import { X402Facilitator, type X402Receipt } from "@coinbase/x402";
import { verifySku } from "./resource-server";

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

type VerifiedIntent = {
  receipt: X402Receipt;
};

const x402 = new X402Facilitator({
  // Coinbase SDK handles x402 intent validation / signature checks.
  // Provide chain / contract config per Coinbase SDK docs.
  chainId: Number(process.env.CHAIN_ID ?? "0")
});

export async function x402SkuMiddleware(
  req: Request,
  res: Response,
  next: NextFunction
) {
  try {
    const intent = req.body as PaymentIntent;

    const receipt = await x402.verifyIntent({
      paymentId: intent.paymentId,
      skuId: intent.skuId,
      agentId: intent.agentId,
      payer: intent.payer,
      amount: intent.amount,
      usdcAuth: intent.usdcAuth
    });

    await verifySku({
      skuId: BigInt(receipt.skuId),
      agentId: BigInt(receipt.agentId)
    });

    res.locals.x402 = { receipt } satisfies VerifiedIntent;

    next();
  } catch (error) {
    res.status(400).json({ ok: false, error: (error as Error).message });
  }
}
