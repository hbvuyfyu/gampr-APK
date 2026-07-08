// ── جمبرة عن بعد (Remote Gambra) hub ─────────────────────────────────────────
// Entry point reached from the home screen's "جمبرة عن بعد" quick action.
// Presents two feature cards mirroring EngineGuardScreen's Jumper/Schedule
// cards, but leading to the manual/remote variants where the customer picks
// the platform + game manually and enters identifiers by hand instead of
// relying on on-device detection. No root check is required here since this
// flow performs no on-device app/ID extraction. Purely additive — does not
// modify the existing Engine (auto-detect) flow in any way.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../theme/app_theme.dart';
import '../../widgets/subscription_guard.dart';
import 'remote_jumper_screen.dart';
import 'remote_schedule_screen.dart';

class RemoteEngineHubScreen extends StatefulWidget {
  const RemoteEngineHubScreen({super.key});
  @override
  State<RemoteEngineHubScreen> createState() => _RemoteEngineHubScreenState();
}

class _RemoteEngineHubScreenState extends State<RemoteEngineHubScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;
  late final AnimationController _logoCtrl;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _glow = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut));
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _logoCtrl.dispose();
    super.dispose();
  }

  Widget _build3DLogo(double size) {
    return AnimatedBuilder(
      animation: _logoCtrl,
      builder: (_, child) {
        final angle = _logoCtrl.value * 2 * 3.14159265;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..rotateY(angle),
          child: child,
        );
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF333333), Color(0xFF0A0A0A)],
          ),
          shape: BoxShape.circle,
          border: Border.all(color: AppTheme.primary.withOpacity(0.4), width: 1),
          boxShadow: [
            BoxShadow(color: Colors.white.withOpacity(0.1), blurRadius: 12, spreadRadius: 1),
            BoxShadow(color: Colors.black.withOpacity(0.8), blurRadius: 8, offset: const Offset(0, 3)),
          ],
        ),
        child: Center(
          child: Stack(alignment: Alignment.center, children: [
            Icon(Icons.diamond_outlined, size: size * 0.5, color: AppTheme.primary),
            Padding(
              padding: EdgeInsets.only(top: size * 0.15),
              child: Text('VIP', style: TextStyle(fontSize: size * 0.18, fontWeight: FontWeight.w900, color: Colors.black, letterSpacing: 1)),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SubscriptionGuard(
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          elevation: 0,
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            _build3DLogo(28),
            const SizedBox(width: 10),
            const Text('جمبرة عن بعد', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.textPrimary)),
          ]),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: AppTheme.textPrimary),
            onPressed: () => context.go('/'),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SizedBox(height: 8),
              Center(
                child: AnimatedBuilder(
                  animation: _glow,
                  builder: (_, __) => Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Colors.white.withOpacity(_glow.value * 0.2), blurRadius: 40, spreadRadius: 8)],
                    ),
                    child: _build3DLogo(110),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Center(child: Text('جمبرة عن بعد', style: TextStyle(
                fontSize: 26, fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontFamily: 'Cairo', letterSpacing: 1,
              ))),
              const SizedBox(height: 8),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.touch_app_outlined, color: AppTheme.warning, size: 13),
                    const SizedBox(width: 6),
                    const Text('اختيار يدوي — بدون الحاجة لتطبيق مفتوح أو صلاحيات Root', style: TextStyle(color: AppTheme.warning, fontFamily: 'Cairo', fontSize: 11)),
                  ]),
                ),
              ),

              const SizedBox(height: 28),

              _buildFeatureCard(
                context: context,
                icon: '📡',
                title: 'إرسال حدث عن بعد',
                subtitle: 'Remote Event Sender',
                description: 'اختر المنصة واللعبة يدوياً وأدخل المعرفات، ثم أرسل أي حدث أو لفل',
                isPrimary: true,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RemoteJumperScreen())),
              ),
              const SizedBox(height: 12),

              _buildFeatureCard(
                context: context,
                icon: '🗓️',
                title: 'جدولة عمليات',
                subtitle: 'Remote Schedule Operations',
                description: 'جدولة إرسال اللفلات/الأحداث تلقائياً باختيار يدوي للمنصة واللعبة والمعرفات',
                isPrimary: false,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RemoteScheduleScreen())),
              ),

              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline, color: AppTheme.textSecondary, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'هذه الميزة مخصصة للعمل عن بعد: تختار المنصة واللعبة يدوياً وتدخل المعرفات (GAID / AF UID) بنفسك، وتتابع باقي الخطوات (اختيار اللفل أو التخصيص والإرسال أو الجدولة) بنفس طريقة محرك Engine الأساسي تماماً.',
                    style: TextStyle(color: AppTheme.textSecondary.withOpacity(0.8), fontFamily: 'Cairo', fontSize: 12, height: 1.5),
                  )),
                ]),
              ),
              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureCard({
    required BuildContext context,
    required String icon,
    required String title,
    required String subtitle,
    required String description,
    required bool isPrimary,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedBuilder(
          animation: _glow,
          builder: (_, __) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            decoration: BoxDecoration(
              color: isPrimary ? AppTheme.primary : AppTheme.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: isPrimary ? AppTheme.primary : AppTheme.glassBorder, width: isPrimary ? 1 : 0.5),
              boxShadow: isPrimary
                  ? [BoxShadow(color: Colors.white.withOpacity(_glow.value * 0.15), blurRadius: 30, spreadRadius: 2)]
                  : [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Row(children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: isPrimary ? Colors.black.withOpacity(0.08) : AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: isPrimary ? Colors.black.withOpacity(0.1) : AppTheme.border, width: 0.5),
                ),
                child: Center(child: Text(icon, style: TextStyle(fontSize: 26, color: isPrimary ? Colors.black : AppTheme.textPrimary))),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo', color: isPrimary ? Colors.black : AppTheme.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 10, fontFamily: 'Courier', letterSpacing: 1.2, color: isPrimary ? Colors.black54 : AppTheme.textSecondary)),
                  const SizedBox(height: 4),
                  Text(description, style: TextStyle(fontSize: 11, fontFamily: 'Cairo', height: 1.4, color: isPrimary ? Colors.black54 : AppTheme.textSecondary.withOpacity(0.7)), maxLines: 2, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_ios, size: 16, color: isPrimary ? Colors.black54 : AppTheme.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }
}
