import { Router } from 'express';
import {
  createPayment,
  uploadProof,
  verifyTxid,
  getPaymentSettings,
  createOxaPayInvoice,
  getPaymentStatus,
  oxapayReturn,
} from '../controllers/payment.controller';
import { authenticate } from '../middleware/auth.middleware';

const router = Router();

// ── Public endpoints ─────────────────────────────────────────────────────────
router.get('/settings', getPaymentSettings);

// OxaPay return URL (browser redirect after payment — mobile WebView intercepts this)
router.get('/oxapay/complete', oxapayReturn);

// ── Authenticated endpoints ──────────────────────────────────────────────────
router.use(authenticate);

router.post('/', createPayment);
router.post('/oxapay/invoice', createOxaPayInvoice);
router.get('/:paymentId/status', getPaymentStatus);
router.post('/:paymentId/proof', uploadProof);
router.post('/:paymentId/verify-txid', verifyTxid);

export default router;
