import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_button.dart';

// ── Human-readable labels for known setting keys ──────────────────────────────
const Map<String, String> _settingLabels = {
  // General
  'app_name':    'اسم التطبيق (إنجليزي)',
  'app_name_ar': 'اسم التطبيق (عربي)',

  // Payment — local methods
  'sham_cash_address':          'رقم Sham Cash',
  'syriatel_cash_address':      'رقم Syriatel Cash',
  'usdt_bep20_address':         'عنوان USDT BEP20',
  'sham_cash_instructions':     'تعليمات Sham Cash',
  'syriatel_cash_instructions': 'تعليمات Syriatel Cash',
  'usdt_instructions':          'تعليمات USDT',

  // Cloudinary
  'cloudinary_cloud_name': 'Cloudinary — Cloud Name',
  'cloudinary_api_key':    'Cloudinary — API Key',
  'cloudinary_api_secret': 'Cloudinary — API Secret',

  // BscScan / Blockchain
  'bscscan_api_key':        'BscScan — API Key',
  'usdt_contract_address':  'عنوان عقد USDT',
  'min_usdt_confirmations': 'الحد الأدنى للتأكيدات',

  // OxaPay
  'oxapay_merchant_key':      'OxaPay — Merchant Key (مفتاح التاجر)',
  'oxapay_currency':          'OxaPay — العملة (USD)',
  'oxapay_lifetime':          'OxaPay — مدة الفاتورة (دقائق)',
  'oxapay_fee_paid_by_payer': 'OxaPay — رسوم على المستخدم (0=لا، 1=نعم)',
  'oxapay_app_url':           'OxaPay — رابط التطبيق (Webhook URL)',
};

// ── Groups display order and Arabic titles ────────────────────────────────────
const Map<String, String> _groupTitles = {
  'general':    'الإعدادات العامة',
  'payment':    'إعدادات الدفع المحلي',
  'oxapay':     '💳 OxaPay — الدفع التلقائي بـ USDT',
  'cloudinary': 'Cloudinary — رفع الصور',
  'blockchain': 'بلوكشين — التحقق من USDT',
};

const List<String> _groupOrder = [
  'oxapay',
  'payment',
  'general',
  'cloudinary',
  'blockchain',
];

class AdminSettingsScreen extends StatefulWidget {
  const AdminSettingsScreen({super.key});
  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  Map<String, List<dynamic>> _grouped = {};
  bool _loading = true;
  String? _error;
  final Map<String, TextEditingController> _controllers = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _controllers.forEach((_, c) => c.dispose());
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await ApiService.get('/settings');
      if (res['success'] == true) {
        final settings = (res['data'] as List?) ?? [];

        // Dispose old controllers
        _controllers.forEach((_, c) => c.dispose());
        _controllers.clear();

        for (final s in settings) {
          final key = s['key'] as String;
          _controllers[key] = TextEditingController(text: s['value'] as String? ?? '');
        }

        // Group by group field
        final Map<String, List<dynamic>> grouped = {};
        for (final s in settings) {
          final group = (s['group'] as String?) ?? 'general';
          grouped.putIfAbsent(group, () => []).add(s);
        }
        setState(() => _grouped = grouped);
      } else {
        setState(() => _error = res['message']?.toString() ?? 'فشل تحميل الإعدادات');
      }
    } catch (_) {
      setState(() => _error = 'خطأ في الاتصال بالسيرفر');
    }
    setState(() => _loading = false);
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      final allSettings = _grouped.values
          .expand((list) => list)
          .map((s) => {
                'key':   s['key'],
                'value': _controllers[s['key']]?.text ?? (s['value'] as String? ?? ''),
                'group': s['group'] ?? 'general',
              })
          .toList();

      final res = await ApiService.put('/settings/bulk', {'settings': allSettings});
      if (!mounted) return;
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('تم حفظ الإعدادات بنجاح', style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppTheme.success,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message']?.toString() ?? 'فشل الحفظ', style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('فشل الحفظ', style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.error,
      ));
    }
    setState(() => _saving = false);
  }

  // Determine which keys should be shown as obscured (password fields)
  bool _isSecret(String key) {
    return key.contains('key') ||
        key.contains('secret') ||
        key.contains('password') ||
        key.contains('merchant');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات', style: TextStyle(fontFamily: 'Cairo')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : _error != null
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.error_outline, color: AppTheme.error, size: 48),
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: AppTheme.error, fontFamily: 'Cairo')),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadSettings,
                      child: const Text('إعادة المحاولة', style: TextStyle(fontFamily: 'Cairo')),
                    ),
                  ]),
                )
              : _grouped.isEmpty
                  ? const Center(
                      child: Text('لا توجد إعدادات بعد', style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo')),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Render groups in defined order, then any extras
                          ...[
                            ..._groupOrder,
                            ..._grouped.keys.where((g) => !_groupOrder.contains(g)),
                          ].where((g) => _grouped.containsKey(g)).map((group) {
                            final items = _grouped[group]!;
                            final title = _groupTitles[group] ?? group;
                            return _buildGroup(title, group, items);
                          }),
                          const SizedBox(height: 24),
                          GradientButton(
                            onPressed: _saving ? null : _saveAll,
                            isLoading: _saving,
                            text: 'حفظ جميع الإعدادات',
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
    );
  }

  Widget _buildGroup(String title, String group, List<dynamic> items) {
    final isOxaPay = group == 'oxapay';
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: isOxaPay
            ? const Color(0xFF10B981).withOpacity(0.05)
            : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOxaPay
              ? const Color(0xFF10B981).withOpacity(0.3)
              : AppTheme.border,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Group header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isOxaPay ? const Color(0xFF10B981) : AppTheme.textPrimary,
              fontFamily: 'Cairo',
            ),
          ),
        ),
        if (isOxaPay)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              'احصل على Merchant Key من حسابك على oxapay.com ← Settings ← API Keys',
              style: TextStyle(
                fontSize: 11,
                color: const Color(0xFF10B981).withOpacity(0.7),
                fontFamily: 'Cairo',
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: items.map((s) {
              final key     = s['key'] as String;
              final label   = _settingLabels[key] ?? key;
              final secret  = _isSecret(key);
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _SecretTextField(
                  controller: _controllers[key]!,
                  label:      label,
                  isSecret:   secret,
                ),
              );
            }).toList(),
          ),
        ),
      ]),
    );
  }
}

// ── Helper widget: text field with show/hide toggle for secret values ─────────
class _SecretTextField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final bool isSecret;

  const _SecretTextField({
    required this.controller,
    required this.label,
    required this.isSecret,
  });

  @override
  State<_SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<_SecretTextField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: widget.isSecret && _obscure,
      style: const TextStyle(fontFamily: 'Cairo', fontSize: 14),
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
        suffixIcon: widget.isSecret
            ? IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              )
            : null,
      ),
    );
  }
}
