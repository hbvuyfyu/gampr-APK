import { Request, Response } from 'express';
import prisma, { withDb } from '../utils/prisma';
import { AuthRequest } from '../middleware/auth.middleware';
import axios from 'axios';
import { v2 as cloudinary } from 'cloudinary';
import * as crypto from 'crypto';

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

const configureCloudinary = async () => {
  const [cloudName, apiKey, apiSecret] = await Promise.all([
    prisma.settings.findUnique({ where: { key: 'cloudinary_cloud_name' } }),
    prisma.settings.findUnique({ where: { key: 'cloudinary_api_key' } }),
    prisma.settings.findUnique({ where: { key: 'cloudinary_api_secret' } }),
  ]);
  cloudinary.config({
    cloud_name: cloudName?.value || process.env.CLOUDINARY_CLOUD_NAME,
    api_key: apiKey?.value || process.env.CLOUDINARY_API_KEY,
    api_secret: apiSecret?.value || process.env.CLOUDINARY_API_SECRET,
  });
};

export const getPaymentSettings = async (_req: any, res: Response): Promise<void> => {
  try {
    const settings = await withDb(() => prisma.settings.findMany({ where: { group: 'payment' } }));
    const result: Record<string, string> = {};
    settings.forEach(s => { result[s.key] = s.value; });
    res.json({ success: true, data: result });
  } catch (err) {
    console.error('[getPaymentSettings]', errMsg(err));
    res.status(500).json({ success: false, message: 'خطأ في السيرفر' });
  }
};

export const createPayment = async (req: AuthRequest, res: Response): Promise<void> => {
  try {
    const { planId, method } = req.body;
    if (!planId || !method) {
      res.status(400).json({ success: false, message: 'planId و method مطلوبان' });
      return;
    }
    const plan = await withDb(() => prisma.plan.findUnique({ where: { id: planId } }));
    if (!plan || !plan.isActive) {
      res.status(404).json({ success: false, message: 'الباقة غير موجودة' });
      return;
    }

    const existingActive = await withDb(() =>
      prisma.subscription.findFirst({
        where: { userId: req.user!.id, status: 'ACTIVE', endDate: { gt: new Date() } },
      })
    );
    if (existingActive) {
      res.status(409).json({ success: false, message: 'لديك اشتراك نشط بالفعل' });
      return;
    }

    const existingPending = await withDb(() =>
      prisma.payment.findFirst({
        where: { userId: req.user!.id, planId, status: 'PENDING' },
      })
    );
    if (existingPending) {
      res.status(409).json({
        success: false,
        message: 'لديك طلب دفع معلّق لهذه الباقة بالفعل، انتظر موافقة الأدمن',
        data: existingPending,
      });
      return;
    }

    const payment = await withDb(() =>
      prisma.payment.create({
        data: { userId: req.user!.id, planId, method, amount: plan.price, status: 'PENDING' },
        include: { plan: true },
      })
    );
    res.status(201).json({ success: true, data: payment });
  } catch (err) {
    console.error('[createPayment]', errMsg(err));
    res.status(500).json({ success: false, message: 'خطأ في السيرفر' });
  }
};

export const uploadProof = async (req: AuthRequest, res: Response): Promise<void> => {
  try {
    const { paymentId } = req.params;
    const payment = await withDb(() =>
      prisma.payment.findFirst({
        where: { id: paymentId, userId: req.user!.id, status: 'PENDING' },
      })
    );
    if (!payment) {
      res.status(404).json({ success: false, message: 'الدفع غير موجود' });
      return;
    }
    if (!req.body.imageBase64) {
      res.status(400).json({ success: false, message: 'الصورة مطلوبة' });
      return;
    }

    const imageBase64: string = req.body.imageBase64;

    let proofImageUrl: string | null = null;
    let proofImageBase64: string | null = null;
    let cloudinaryOk = false;

    try {
      await configureCloudinary();
      const uploadResult = await cloudinary.uploader.upload(
        imageBase64.startsWith('data:') ? imageBase64 : `data:image/jpeg;base64,${imageBase64}`,
        { folder: 'payment_proofs', resource_type: 'image' }
      );
      proofImageUrl = uploadResult.secure_url;
      cloudinaryOk = true;
    } catch (cloudErr) {
      console.warn('[uploadProof] Cloudinary failed, storing base64 in DB:', errMsg(cloudErr));
    }

    if (!cloudinaryOk) {
      proofImageBase64 = imageBase64.startsWith('data:') ? imageBase64 : `data:image/jpeg;base64,${imageBase64}`;
    }

    await withDb(() =>
      prisma.payment.update({
        where: { id: paymentId },
        data: { proofImageUrl, proofImageBase64 },
      })
    );

    res.json({ success: true, message: 'تم رفع الإيصال بنجاح، سيتم مراجعته قريباً' });
  } catch (err) {
    console.error('[uploadProof]', errMsg(err));
    res.status(500).json({ success: false, message: 'خطأ في السيرفر' });
  }
};

export const verifyTxid = async (req: AuthRequest, res: Response): Promise<void> => {
  try {
    const { paymentId } = req.params;
    const { txid } = req.body;
    if (!txid) {
      res.status(400).json({ success: false, message: 'TXID مطلوب' });
      return;
    }

    const payment = await withDb(() =>
      prisma.payment.findFirst({
        where: { id: paymentId, userId: req.user!.id, status: 'PENDING', method: 'USDT_BEP20' },
      })
    );
    if (!payment) {
      res.status(404).json({ success: false, message: 'الدفع غير موجود' });
      return;
    }

    const existingTxid = await withDb(() => prisma.usedTxid.findUnique({ where: { txid } }));
    if (existingTxid) {
      res.status(400).json({ success: false, message: 'هذا TXID مستخدم مسبقاً' });
      return;
    }

    const apiKeyRow = await withDb(() => prisma.settings.findUnique({ where: { key: 'bscscan_api_key' } }));
    const contractRow = await withDb(() => prisma.settings.findUnique({ where: { key: 'usdt_contract_address' } }));
    const apiKey = apiKeyRow?.value || process.env.BSCSCAN_API_KEY || '';
    const contract = contractRow?.value || '0x55d398326f99059fF775485246999027B3197955';

    let txValid = false;
    try {
      const response = await axios.get('https://api.bscscan.com/api', {
        params: {
          module: 'proxy',
          action: 'eth_getTransactionByHash',
          txhash: txid,
          apikey: apiKey,
        },
        timeout: 15000,
      });
      const tx = response.data?.result;
      if (tx && tx.to && tx.to.toLowerCase() === contract.toLowerCase()) {
        txValid = true;
      }
    } catch {
      res.status(502).json({ success: false, message: 'فشل التحقق من البلوكشين، حاول مرة أخرى' });
      return;
    }

    if (!txValid) {
      res.status(400).json({ success: false, message: 'TXID غير صالح أو المعاملة غير موجودة' });
      return;
    }

    await withDb(() => prisma.usedTxid.create({ data: { txid, userId: req.user!.id } }));
    await withDb(() =>
      prisma.payment.update({
        where: { id: paymentId },
        data: { txid, txidVerified: true },
      })
    );

    res.json({
      success: true,
      message: 'تم التحقق من TXID بنجاح. سيتم تفعيل اشتراكك بعد مراجعة الأدمن.',
    });
  } catch (err) {
    console.error('[verifyTxid]', errMsg(err));
    res.status(500).json({ success: false, message: 'خطأ في السيرفر' });
  }
};

// ── OxaPay: Create Invoice ───────────────────────────────────────────────────

export const createOxaPayInvoice = async (req: AuthRequest, res: Response): Promise<void> => {
  try {
    const { planId } = req.body;
    if (!planId) {
      res.status(400).json({ success: false, message: 'planId مطلوب' });
      return;
    }

    const plan = await withDb(() => prisma.plan.findUnique({ where: { id: planId } }));
    if (!plan || !plan.isActive) {
      res.status(404).json({ success: false, message: 'الباقة غير موجودة' });
      return;
    }

    // Block if user already has an active subscription
    const existingActive = await withDb(() =>
      prisma.subscription.findFirst({
        where: { userId: req.user!.id, status: 'ACTIVE', endDate: { gt: new Date() } },
      })
    );
    if (existingActive) {
      res.status(409).json({ success: false, message: 'لديك اشتراك نشط بالفعل' });
      return;
    }

    // Reject if there's already a PENDING OXAPAY_USDT payment for this plan
    const existingPending = await withDb(() =>
      prisma.payment.findFirst({
        where: { userId: req.user!.id, planId, status: 'PENDING', method: 'OXAPAY_USDT' },
      })
    );
    if (existingPending) {
      res.status(409).json({
        success: false,
        message: 'لديك فاتورة دفع معلّقة لهذه الباقة، انتظر اكتمالها أو انتهاء صلاحيتها',
        data: { paymentId: existingPending.id },
      });
      return;
    }

    // Load OxaPay settings
    const [merchantKeyRow, currencyRow, lifetimeRow, feePaidRow, appUrlRow] = await Promise.all([
      withDb(() => prisma.settings.findUnique({ where: { key: 'oxapay_merchant_key' } })),
      withDb(() => prisma.settings.findUnique({ where: { key: 'oxapay_currency' } })),
      withDb(() => prisma.settings.findUnique({ where: { key: 'oxapay_lifetime' } })),
      withDb(() => prisma.settings.findUnique({ where: { key: 'oxapay_fee_paid_by_payer' } })),
      withDb(() => prisma.settings.findUnique({ where: { key: 'oxapay_app_url' } })),
    ]);

    const merchantKey = merchantKeyRow?.value || process.env.OXAPAY_MERCHANT_KEY || '';
    if (!merchantKey || merchantKey.trim() === '') {
      res.status(503).json({ success: false, message: 'خدمة OxaPay غير مفعّلة حالياً. تواصل مع الدعم.' });
      return;
    }

    const currency     = currencyRow?.value    || process.env.OXAPAY_CURRENCY    || 'USD';
    const lifeTime     = parseInt(lifetimeRow?.value || process.env.OXAPAY_LIFETIME || '30', 10);
    const feePaidByPayer = parseInt(feePaidRow?.value || '0', 10);
    const appUrl       = appUrlRow?.value      || process.env.APP_URL            || 'https://gampr-apk-production.up.railway.app';

    // Create a PENDING payment record first so we have the ID for callbackUrl
    const payment = await withDb(() =>
      prisma.payment.create({
        data: {
          userId: req.user!.id,
          planId,
          method:  'OXAPAY_USDT',
          amount:  plan.price,
          status:  'PENDING',
        },
      })
    );

    const callbackUrl = `${appUrl}/api/payments/oxapay-webhook`;
    const returnUrl   = `${appUrl}/api/payments/oxapay/complete?paymentId=${payment.id}`;

    // Call OxaPay API to create invoice
    let oxaPayResponse: any;
    try {
      const response = await axios.post(
        'https://api.oxapay.com/merchants/request',
        {
          merchant:      merchantKey,
          amount:        plan.price,
          currency,
          lifeTime,
          feePaidByPayer,
          callbackUrl,
          returnUrl,
          description:   `اشتراك - ${plan.nameAr || plan.name}`,
          orderId:       payment.id,
        },
        {
          timeout: 20000,
          headers: { 'Content-Type': 'application/json' },
        }
      );
      oxaPayResponse = response.data;
    } catch (axiosErr) {
      // Roll back: delete the pending payment record since invoice creation failed
      await withDb(() => prisma.payment.delete({ where: { id: payment.id } })).catch(() => {});
      console.error('[createOxaPayInvoice] OxaPay API error:', errMsg(axiosErr));
      res.status(502).json({ success: false, message: 'فشل الاتصال بـ OxaPay، حاول مرة أخرى' });
      return;
    }

    // OxaPay returns result=100 on success
    if (oxaPayResponse?.result !== 100 || !oxaPayResponse?.payLink) {
      await withDb(() => prisma.payment.delete({ where: { id: payment.id } })).catch(() => {});
      console.error('[createOxaPayInvoice] OxaPay rejected request:', oxaPayResponse);
      res.status(502).json({
        success: false,
        message: oxaPayResponse?.message || 'فشل إنشاء فاتورة OxaPay',
      });
      return;
    }

    // Store the OxaPay track ID in the payment record
    const trackId = String(oxaPayResponse.trackId ?? '');
    await withDb(() =>
      prisma.payment.update({
        where: { id: payment.id },
        data:  { oxapayTrackId: trackId },
      })
    );

    res.status(201).json({
      success: true,
      data: {
        paymentId: payment.id,
        payLink:   oxaPayResponse.payLink as string,
        trackId,
        amount:    plan.price,
        currency,
      },
    });
  } catch (err) {
    console.error('[createOxaPayInvoice]', errMsg(err));
    res.status(500).json({ success: false, message: 'خطأ في السيرفر' });
  }
};

// ── OxaPay: Webhook (called automatically by OxaPay servers) ────────────────
// NO authentication middleware — secured via HMAC-SHA512 signature verification
// Security: constant-time HMAC comparison, atomic DB state transition

export const oxapayWebhook = async (req: Request, res: Response): Promise<void> => {
  try {
    const body = req.body as Record<string, unknown>;

    // ── 1. Verify HMAC-SHA512 signature (constant-time) ──────────────────────
    const receivedHmac = body.hmac as string | undefined;
    if (!receivedHmac) {
      console.warn('[oxapayWebhook] Missing HMAC in request');
      res.status(400).json({ success: false, message: 'Missing HMAC' });
      return;
    }

    const merchantKeyRow = await withDb(() =>
      prisma.settings.findUnique({ where: { key: 'oxapay_merchant_key' } })
    );
    const merchantKey = merchantKeyRow?.value || process.env.OXAPAY_MERCHANT_KEY || '';
    if (!merchantKey) {
      console.error('[oxapayWebhook] Merchant key not configured');
      res.status(500).json({ success: false, message: 'Configuration error' });
      return;
    }

    // Build HMAC: sort all fields (excluding 'hmac') alphabetically,
    // join as "key=value" pairs separated by "&", then compute HMAC-SHA512
    const filteredFields = Object.entries(body)
      .filter(([k]) => k !== 'hmac')
      .sort(([a], [b]) => a.localeCompare(b));

    const dataString = filteredFields
      .map(([k, v]) => `${k}=${String(v ?? '')}`)
      .join('&');

    const expectedHmac = crypto
      .createHmac('sha512', merchantKey)
      .update(dataString)
      .digest('hex');

    // Constant-time comparison to prevent timing attacks
    const expectedBuf = Buffer.from(expectedHmac, 'utf8');
    const receivedBuf = Buffer.from(receivedHmac,  'utf8');
    const hmacValid =
      expectedBuf.length === receivedBuf.length &&
      crypto.timingSafeEqual(expectedBuf, receivedBuf);

    if (!hmacValid) {
      console.warn('[oxapayWebhook] HMAC verification failed');
      res.status(401).json({ success: false, message: 'Invalid signature' });
      return;
    }

    // ── 2. Parse and validate webhook payload ────────────────────────────────
    const status  = body.status  as string | undefined;
    const orderId = body.orderId as string | undefined;   // Our internal payment ID
    const trackId = body.trackId !== undefined ? String(body.trackId) : undefined;

    if (!orderId) {
      console.warn('[oxapayWebhook] Missing orderId in webhook');
      res.status(400).json({ success: false, message: 'Missing orderId' });
      return;
    }

    // Only process successful payments — acknowledge all others immediately
    if (status !== 'Paid') {
      console.log(`[oxapayWebhook] Payment ${orderId} status: ${status} — acknowledged, no action`);
      res.json({ success: true });
      return;
    }

    // ── 3. Atomic idempotent state transition ─────────────────────────────────
    // Use updateMany with PENDING+OXAPAY_USDT guard to prevent race conditions:
    // only one concurrent webhook call will succeed; duplicates get count=0 and skip.
    const claimed = await withDb(() =>
      prisma.payment.updateMany({
        where: {
          id:     orderId,
          status: 'PENDING',
          method: 'OXAPAY_USDT',
        },
        data: {
          status:        'APPROVED',
          oxapayTrackId: trackId,
          reviewedAt:    new Date(),
          notes:         'تمت الموافقة تلقائياً عبر OxaPay',
        },
      })
    );

    if (claimed.count === 0) {
      // Either already processed (idempotent), doesn't exist, or wrong method
      console.log(`[oxapayWebhook] Payment ${orderId} — no PENDING record to claim (already processed or invalid)`);
      res.json({ success: true });
      return;
    }

    // ── 4. Payment claimed — load it and create subscription ─────────────────
    const payment = await withDb(() =>
      prisma.payment.findUnique({
        where:   { id: orderId },
        include: { plan: true },
      })
    );

    if (!payment) {
      // Should not happen — we just updated it — but guard defensively
      console.error(`[oxapayWebhook] Payment ${orderId} missing after claim — data inconsistency`);
      res.status(500).json({ success: false, message: 'Internal error' });
      return;
    }

    // Cancel any existing active subscriptions for this user
    await withDb(() =>
      prisma.subscription.updateMany({
        where: { userId: payment.userId, status: 'ACTIVE' },
        data:  { status: 'CANCELLED' },
      })
    );

    const startDate = new Date();
    const endDate   = new Date();
    endDate.setDate(endDate.getDate() + payment.plan.durationDays);

    const subscription = await withDb(() =>
      prisma.subscription.create({
        data: {
          userId:    payment.userId,
          planId:    payment.planId,
          status:    'ACTIVE',
          startDate,
          endDate,
        },
      })
    );

    // Link subscription to the payment record
    await withDb(() =>
      prisma.payment.update({
        where: { id: orderId },
        data:  { subscriptionId: subscription.id },
      })
    );

    await withDb(() =>
      prisma.adminLog.create({
        data: {
          adminId:  payment.userId,
          targetId: payment.userId,
          action:   'PAYMENT_AUTO_APPROVED',
          details:  `OxaPay webhook: payment ${orderId} (trackId: ${trackId ?? 'n/a'}) approved automatically`,
        },
      })
    );

    console.log(`[oxapayWebhook] ✅ Payment ${orderId} auto-approved — subscription ${subscription.id} activated`);

    // Respond success AFTER durable processing so OxaPay retries on failures
    res.json({ success: true });
  } catch (err) {
    console.error('[oxapayWebhook]', errMsg(err));
    // Return 500 so OxaPay retries — webhook was not durably processed
    if (!res.headersSent) {
      res.status(500).json({ success: false, message: 'Processing error — will retry' });
    }
  }
};

// ── OxaPay: Return URL handler (browser redirect after payment) ──────────────
// Called when OxaPay redirects the user back — mobile WebView intercepts this URL

export const oxapayReturn = async (_req: Request, res: Response): Promise<void> => {
  // The mobile WebView intercepts this URL client-side.
  // This endpoint exists as a fallback for web browsers.
  res.send(`
    <!DOCTYPE html>
    <html dir="rtl">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>جارٍ المعالجة...</title>
        <style>
          body { font-family: Cairo, sans-serif; display: flex; align-items: center;
                 justify-content: center; height: 100vh; margin: 0;
                 background: #0a0a0a; color: #fff; text-align: center; }
          .msg { max-width: 320px; padding: 20px; }
          .spinner { width: 48px; height: 48px; border: 4px solid #333;
                     border-top-color: #7c3aed; border-radius: 50%;
                     animation: spin 0.8s linear infinite; margin: 0 auto 16px; }
          @keyframes spin { to { transform: rotate(360deg); } }
        </style>
        <script>setTimeout(() => window.close(), 3000);</script>
      </head>
      <body>
        <div class="msg">
          <div class="spinner"></div>
          <p>جارٍ التحقق من الدفع... يمكنك إغلاق هذه الصفحة والعودة للتطبيق.</p>
        </div>
      </body>
    </html>
  `);
};

// ── Get Payment Status (for mobile polling) ──────────────────────────────────

export const getPaymentStatus = async (req: AuthRequest, res: Response): Promise<void> => {
  try {
    const { paymentId } = req.params;
    const payment = await withDb(() =>
      prisma.payment.findFirst({
        where:  { id: paymentId, userId: req.user!.id },
        select: { id: true, status: true, method: true, amount: true, createdAt: true },
      })
    );
    if (!payment) {
      res.status(404).json({ success: false, message: 'الدفع غير موجود' });
      return;
    }
    res.json({ success: true, data: payment });
  } catch (err) {
    console.error('[getPaymentStatus]', errMsg(err));
    res.status(500).json({ success: false, message: 'خطأ في السيرفر' });
  }
};
