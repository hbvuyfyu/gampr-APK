import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/api_service.dart';
import '../../config/app_config.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_button.dart';

class PaymentScreen extends StatefulWidget {
  final String planId;
  const PaymentScreen({super.key, required this.planId});
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  Map<String, dynamic>? _plan;
  bool _loading = true;
  String? _selectedMethod;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final res = await ApiService.get('/plans', auth: false);
      if (res['success'] == true) {
        final plans = (res['data'] as List?) ?? [];
        final plan = plans.firstWhere(
          (p) => (p as Map)['id'] == widget.planId,
          orElse: () => null,
        );
        setState(() => _plan = plan as Map<String, dynamic>?);
      }
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _proceed() async {
    if (_selectedMethod == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('اختر طريقة الدفع أولاً', style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.warning,
      ));
      return;
    }

    setState(() => _processing = true);

    try {
      if (_selectedMethod == 'OXAPAY_USDT') {
        await _proceedOxaPay();
      } else {
        await _proceedStandard();
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('خطأ في الاتصال بالسيرفر', style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.error,
      ));
    }

    if (mounted) setState(() => _processing = false);
  }

  // OxaPay: create invoice and open WebView
  Future<void> _proceedOxaPay() async {
    final res = await ApiService.post('/payments/oxapay/invoice', {
      'planId': widget.planId,
    });
    if (!mounted) return;

    if (res['success'] == true) {
      final data      = res['data'] as Map<String, dynamic>;
      final paymentId = data['paymentId'] as String;
      final payLink   = data['payLink']   as String;
      context.push('/payment/$paymentId/oxapay?payLink=${Uri.encodeComponent(payLink)}');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          res['message']?.toString() ?? 'فشل إنشاء فاتورة OxaPay',
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: AppTheme.error,
      ));
    }
  }

  // Standard methods (Sham Cash, Syriatel Cash): no payment request is
  // created yet — the customer must first see the payment address, transfer
  // the money, upload proof, and press "confirm/send" on the next screen.
  // Only then is the payment request actually created and made visible to
  // the admin (see PaymentProofScreen._submit).
  Future<void> _proceedStandard() async {
    if (!mounted) return;
    context.push('/payment/${widget.planId}/proof?method=$_selectedMethod');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إتمام الدفع'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _buildSummary(),
                const SizedBox(height: 24),
                _buildMethods(),
                const SizedBox(height: 24),
                GradientButton(
                  onPressed: _processing ? null : _proceed,
                  isLoading: _processing,
                  text: 'متابعة',
                ),
              ]),
            ),
    );
  }

  Widget _buildSummary() {
    if (_plan == null) return const SizedBox();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1A1A), Color(0xFF0A0A0A)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.glassBorder, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _plan!['name'] ?? '',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
                fontFamily: 'Cairo',
              ),
            ),
            Text(
              '${_plan!['durationDays']} يوم | ${_plan!['dailyOperations']} عملية/يوم',
              style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo'),
            ),
          ]),
        ),
        Text(
          '\$${_plan!['price']}',
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: AppTheme.accent,
            fontFamily: 'Cairo',
          ),
        ),
      ]),
    );
  }

  Widget _buildMethods() {
    final methods = [
      {
        'value': 'SHAM_CASH',
        'label': 'Sham Cash',
        'icon': Icons.account_balance_wallet_outlined,
        'color': AppTheme.primary,
        'badge': null,
      },
      {
        'value': 'SYRIATEL_CASH',
        'label': 'Syriatel Cash',
        'icon': Icons.phone_android_outlined,
        'color': AppTheme.success,
        'badge': null,
      },
      {
        'value': 'OXAPAY_USDT',
        'label': 'USDT عبر OxaPay',
        'icon': Icons.bolt_outlined,
        'color': const Color(0xFF10B981),
        'badge': 'تلقائي ✓',
      },
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text(
        'طريقة الدفع',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: AppTheme.textPrimary,
          fontFamily: 'Cairo',
        ),
      ),
      const SizedBox(height: 12),
      ...methods.map((m) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: () => setState(() => _selectedMethod = m['value'] as String),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _selectedMethod == m['value']
                  ? (m['color'] as Color).withOpacity(0.15)
                  : AppTheme.cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _selectedMethod == m['value']
                    ? m['color'] as Color
                    : AppTheme.border,
                width: _selectedMethod == m['value'] ? 2 : 1,
              ),
            ),
            child: Row(children: [
              Icon(m['icon'] as IconData, color: m['color'] as Color, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    m['label'] as String,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _selectedMethod == m['value']
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontFamily: 'Cairo',
                    ),
                  ),
                  if (m['badge'] != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: (m['color'] as Color).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: (m['color'] as Color).withOpacity(0.5),
                        ),
                      ),
                      child: Text(
                        m['badge'] as String,
                        style: TextStyle(
                          fontSize: 11,
                          color: m['color'] as Color,
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
              if (_selectedMethod == m['value'])
                Icon(Icons.check_circle, color: m['color'] as Color, size: 24),
            ]),
          ),
        ),
      )),
    ]);
  }
}
