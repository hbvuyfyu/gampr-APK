import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../services/api_service.dart';
import '../../config/app_config.dart';
import '../../theme/app_theme.dart';

class OxaPayPaymentScreen extends StatefulWidget {
  final String paymentId;
  final String payLink;

  const OxaPayPaymentScreen({
    super.key,
    required this.paymentId,
    required this.payLink,
  });

  @override
  State<OxaPayPaymentScreen> createState() => _OxaPayPaymentScreenState();
}

class _OxaPayPaymentScreenState extends State<OxaPayPaymentScreen> {
  late final WebViewController _webViewController;
  bool _isLoading = true;
  bool _isCheckingStatus = false;
  bool _paymentCompleted = false;
  Timer? _pollingTimer;
  String _statusMessage = 'في انتظار إتمام الدفع...';

  @override
  void initState() {
    super.initState();
    _initWebView();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _initWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) => setState(() => _isLoading = false),
          onWebResourceError: (error) {
            setState(() => _isLoading = false);
          },
          onNavigationRequest: (request) {
            // Intercept the return URL to detect payment completion
            if (request.url.contains('/oxapay/complete') ||
                request.url.contains('/oxapay-return') ||
                request.url.contains('oxapay.com/pay') == false &&
                    request.url.contains('oxapay') == false &&
                    request.url.contains(AppConfig.baseUrl)) {
              _checkPaymentStatus();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.payLink));
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_paymentCompleted && mounted) {
        _checkPaymentStatus();
      }
    });
  }

  Future<void> _checkPaymentStatus() async {
    if (_isCheckingStatus || _paymentCompleted || !mounted) return;

    setState(() => _isCheckingStatus = true);

    try {
      final res = await ApiService.get('/payments/${widget.paymentId}/status');
      if (!mounted) return;

      if (res['success'] == true) {
        final status = res['data']?['status'] as String?;

        if (status == 'APPROVED') {
          _pollingTimer?.cancel();
          setState(() {
            _paymentCompleted = true;
            _statusMessage = 'تم الدفع بنجاح! جارٍ تفعيل الاشتراك...';
          });
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            _showSuccessDialog();
          }
        } else if (status == 'REJECTED') {
          _pollingTimer?.cancel();
          setState(() {
            _paymentCompleted = true;
            _statusMessage = 'فشل الدفع. يرجى المحاولة مرة أخرى.';
          });
          if (mounted) {
            _showErrorDialog('فشل الدفع أو انتهت صلاحية الفاتورة. يرجى المحاولة مرة أخرى.');
          }
        }
      }
    } catch (_) {
      // Silent fail — will retry on next poll cycle
    }

    if (mounted) setState(() => _isCheckingStatus = false);
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, color: AppTheme.success, size: 64),
            const SizedBox(height: 16),
            const Text(
              'تم الدفع بنجاح!',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
                fontFamily: 'Cairo',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'تم تفعيل اشتراكك تلقائياً. استمتع بالخدمة!',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontFamily: 'Cairo',
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.go('/');
            },
            child: const Text(
              'الذهاب للرئيسية',
              style: TextStyle(color: AppTheme.primary, fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.error, size: 64),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontFamily: 'Cairo',
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.pop();
            },
            child: const Text(
              'حسناً',
              style: TextStyle(color: AppTheme.primary, fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'الدفع بـ USDT',
          style: TextStyle(fontFamily: 'Cairo'),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => _confirmCancel(),
        ),
        actions: [
          if (_isCheckingStatus)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: AppTheme.primary,
                  strokeWidth: 2,
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _webViewController),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            ),
          // Bottom status bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.cardBg.withOpacity(0.95),
                border: const Border(top: BorderSide(color: AppTheme.border)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusMessage,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _isCheckingStatus ? null : _checkPaymentStatus,
                    child: const Text(
                      'تحقق الآن',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCancel() async {
    if (_paymentCompleted) {
      context.pop();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'إلغاء الدفع؟',
          style: TextStyle(color: AppTheme.textPrimary, fontFamily: 'Cairo'),
        ),
        content: const Text(
          'هل تريد الخروج؟ إذا أكملت الدفع مسبقاً سيتم تفعيل اشتراكك تلقائياً عند الدخول لاحقاً.',
          style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'البقاء',
              style: TextStyle(color: AppTheme.primary, fontFamily: 'Cairo'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'الخروج',
              style: TextStyle(color: AppTheme.error, fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.pop();
    }
  }
}
