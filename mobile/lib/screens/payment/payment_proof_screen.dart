import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_button.dart';

/// Shows the payment address + instructions for a manual-transfer method
/// (Sham Cash / Syriatel Cash), lets the customer attach proof of payment,
/// and only then creates the actual payment request.
///
/// IMPORTANT: no payment request exists in the database (and therefore the
/// admin cannot see anything) until the customer has picked an image AND
/// pressed "تأكيد الإرسال" below. This is intentional — see
/// payment.controller.ts#createPayment.
class PaymentProofScreen extends StatefulWidget {
  final String planId;
  final String method;
  const PaymentProofScreen({super.key, required this.planId, required this.method});
  @override
  State<PaymentProofScreen> createState() => _PaymentProofScreenState();
}

class _PaymentProofScreenState extends State<PaymentProofScreen> {
  Map<String, dynamic>? _plan;
  Map<String, dynamic>? _settings;
  bool _loading = true;
  XFile? _pickedImage;
  bool _submitting = false;

  @override
  void initState() { super.initState(); _loadData(); }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        ApiService.get('/plans', auth: false),
        ApiService.get('/settings/payment', auth: false),
      ]);
      if (results[0]['success'] == true) {
        final plans = (results[0]['data'] as List?) ?? [];
        _plan = plans.firstWhere(
          (p) => (p as Map)['id'] == widget.planId,
          orElse: () => null,
        ) as Map<String, dynamic>?;
      }
      if (results[1]['success'] == true) {
        _settings = results[1]['data'] as Map<String, dynamic>?;
      }
    } catch (_) {}
    setState(() => _loading = false);
  }

  String get _address {
    if (widget.method == 'SHAM_CASH') return (_settings?['sham_cash_address'] ?? '').toString();
    if (widget.method == 'SYRIATEL_CASH') return (_settings?['syriatel_cash_address'] ?? '').toString();
    return '';
  }

  String get _instructions {
    if (widget.method == 'SHAM_CASH') return (_settings?['sham_cash_instructions'] ?? '').toString();
    if (widget.method == 'SYRIATEL_CASH') return (_settings?['syriatel_cash_instructions'] ?? '').toString();
    return '';
  }

  String get _methodLabel {
    if (widget.method == 'SHAM_CASH') return 'Sham Cash';
    if (widget.method == 'SYRIATEL_CASH') return 'Syriatel Cash';
    return widget.method;
  }

  void _copyAddress() {
    if (_address.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _address));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('تم نسخ العنوان', style: TextStyle(fontFamily: 'Cairo')),
      backgroundColor: AppTheme.success,
      duration: Duration(seconds: 1),
    ));
  }

  Future<void> _pickImage() async {
    final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (img != null) setState(() => _pickedImage = img);
  }

  Future<void> _submit() async {
    if (_pickedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('يرجى إرفاق صورة إثبات الدفع أولاً', style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.warning,
      ));
      return;
    }
    setState(() => _submitting = true);
    try {
      final bytes = await File(_pickedImage!.path).readAsBytes();
      final b64 = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      // Single atomic call: creates the payment request AND attaches proof.
      // Nothing reaches the admin before this succeeds.
      final res = await ApiService.post('/payments', {
        'planId': widget.planId,
        'method': widget.method,
        'imageBase64': b64,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('تم إرسال طلب الدفع مع الإثبات، بانتظار موافقة الأدمن', style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppTheme.success,
        ));
        context.go('/');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message']?.toString() ?? 'فشل إرسال طلب الدفع', style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('فشل الإرسال', style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.error,
      ));
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إتمام الدفع وإرفاق الإثبات'),
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios), onPressed: () => context.pop()),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _buildSummaryCard(),
                const SizedBox(height: 16),
                _buildAddressCard(),
                const SizedBox(height: 24),
                const Text(
                  '1) أرسل صورة إثبات الدفع',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontFamily: 'Cairo'),
                ),
                const SizedBox(height: 12),
                _buildImagePicker(),
                const SizedBox(height: 32),
                const Text(
                  '2) اضغط تأكيد الإرسال',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontFamily: 'Cairo'),
                ),
                const SizedBox(height: 12),
                GradientButton(onPressed: _submitting ? null : _submit, isLoading: _submitting, text: 'تأكيد الإرسال'),
                const SizedBox(height: 8),
                const Text(
                  'لن يتم إرسال أي طلب للأدمن قبل رفع الإثبات والضغط على تأكيد الإرسال.',
                  style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 12),
                ),
              ]),
            ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.border)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              (_plan?['name'] ?? '').toString(),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontFamily: 'Cairo'),
            ),
            const SizedBox(height: 4),
            Text('طريقة الدفع: $_methodLabel', style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo')),
          ]),
        ),
        Text(
          '\$${_plan?['price'] ?? ''}',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.accent, fontFamily: 'Cairo'),
        ),
      ]),
    );
  }

  // Payment address: white text on a solid black background, large and
  // easy to copy, with a dedicated copy button plus a tap-to-copy gesture.
  Widget _buildAddressCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withOpacity(0.4), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'أرسل المبلغ إلى هذا الحساب',
          style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: _copyAddress,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(children: [
              Expanded(
                child: Text(
                  _address.isNotEmpty ? _address : '—',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.copy, color: Colors.white, size: 20),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'اضغط على الرقم لنسخه',
          style: TextStyle(color: Colors.white38, fontFamily: 'Cairo', fontSize: 11),
        ),
        if (_instructions.isNotEmpty) ...[
          const Divider(color: Colors.white24, height: 28),
          const Text(
            'تعليمات الدفع',
            style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            _instructions,
            style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 14, height: 1.5),
          ),
        ],
        const SizedBox(height: 6),
        const Text(
          'ثم ارفع صورة إثبات الدفع واضغط تأكيد الإرسال بالأسفل.',
          style: TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold, height: 1.5),
        ),
      ]),
    );
  }

  Widget _buildImagePicker() {
    return InkWell(
      onTap: _pickImage,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 180,
        width: double.infinity,
        decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.border)),
        child: _pickedImage != null
            ? ClipRRect(borderRadius: BorderRadius.circular(15), child: Image.file(File(_pickedImage!.path), fit: BoxFit.cover))
            : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_photo_alternate_outlined, color: AppTheme.primary, size: 48),
                SizedBox(height: 8),
                Text('اضغط لاختيار صورة إثبات الدفع', style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo')),
              ]),
      ),
    );
  }
}
