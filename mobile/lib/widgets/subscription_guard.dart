import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class SubscriptionGuard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSubscriptionRequired;

  const SubscriptionGuard({
    super.key,
    required this.child,
    this.onSubscriptionRequired,
  });

  @override
  State<SubscriptionGuard> createState() => _SubscriptionGuardState();
}

class _SubscriptionGuardState extends State<SubscriptionGuard> with SingleTickerProviderStateMixin {
  bool _checking = true;
  bool _hasSubscription = false;
  Map<String, dynamic>? _subscriptionData;

  late final AnimationController _logoCtrl;

  @override
  void initState() {
    super.initState();
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _checkSubscription();
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkSubscription() async {
    try {
      final res = await ApiService.get('/games/daily-usage');
      if (res['success'] == true && mounted) {
        final data = res['data'] as Map<String, dynamic>?;
        setState(() {
          _subscriptionData = data;
          _hasSubscription = data?['hasSubscription'] == true;
          _checking = false;
        });
      } else {
        setState(() => _checking = false);
      }
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: AppTheme.primary),
              const SizedBox(height: 16),
              Text(
                'جاري التحقق من الاشتراك...',
                style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_hasSubscription) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: AppTheme.textPrimary),
            onPressed: () => context.go('/'),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.error.withOpacity(0.3), width: 2),
                  ),
                  child: const Icon(Icons.lock, color: AppTheme.error, size: 64),
                ),
                const SizedBox(height: 32),
                const Text(
                  'الوصول مرفوض',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.error,
                    fontFamily: 'Cairo',
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.error.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.card_membership, color: AppTheme.error, size: 32),
                      const SizedBox(height: 12),
                      const Text(
                        'هذه الميزة تتطلب اشتراكاً فعّالاً',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                          fontFamily: 'Cairo',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'اشترك في إحدى الباقات للاستفادة من جميع ميزات التطبيق',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => context.go('/plans'),
                    icon: const Icon(Icons.card_membership, color: Colors.black),
                    label: const Text(
                      'عرض الباقات',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.go('/'),
                    icon: const Icon(Icons.arrow_back, color: AppTheme.textSecondary),
                    label: const Text(
                      'العودة للرئيسية',
                      style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo'),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.border),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
