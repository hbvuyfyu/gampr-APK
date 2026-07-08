// ── جمبرة عن بعد — إرسال حدث يدوي ────────────────────────────────────────────
// Manual/remote twin of jumper_engine_screen.dart. Same event-sending logic
// and UI (identifiers section, event picker, custom level, send/result), but
// the platform + game are chosen manually from the catalog instead of being
// auto-detected from a running app on the device, and identifiers are always
// entered manually. This file is purely additive.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/subscription_guard.dart';
import 'remote_common.dart';

enum _RPhase {
  platform,
  game,
  loadingDetail,
  pickEvent,
  sending,
  done,
}

class RemoteJumperScreen extends StatefulWidget {
  const RemoteJumperScreen({super.key});
  @override
  State<RemoteJumperScreen> createState() => _RemoteJumperScreenState();
}

class _RemoteJumperScreenState extends State<RemoteJumperScreen> with SingleTickerProviderStateMixin {
  _RPhase _phase = _RPhase.platform;
  final List<String> _log = [];

  Map<String, dynamic>? _game;
  String? _platform;
  List<Map<String, dynamic>> _events = [];

  final _gaidCtrl = TextEditingController();
  final _afUidCtrl = TextEditingController();

  Map<String, dynamic>? _selectedEvent;
  bool _customLevel = false;
  final _customLevelCtrl = TextEditingController();

  bool _resultOk = false;
  String _resultMsg = '';
  int? _resultHttp;

  Map<String, dynamic>? _dailyUsage;

  // Proxy state
  List<Map<String, dynamic>> _proxies = [];
  String? _selectedProxyId;
  bool _loadingProxies = false;
  Map<String, dynamic>? _proxySettings;

  late final AnimationController _logoCtrl;

  @override
  void initState() {
    super.initState();
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _loadDailyUsage();
  }

  @override
  void dispose() {
    _gaidCtrl.dispose();
    _afUidCtrl.dispose();
    _customLevelCtrl.dispose();
    _logoCtrl.dispose();
    super.dispose();
  }

  void _log$(String msg) {
    if (!mounted) return;
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    setState(() => _log.add('[$ts] $msg'));
  }

  Future<void> _loadDailyUsage() async {
    try {
      final res = await ApiService.get('/games/daily-usage');
      if (res['success'] == true && mounted) {
        setState(() => _dailyUsage = res['data'] as Map<String, dynamic>?);
      }
    } catch (_) {}
    _loadProxies();
  }

  Future<void> _loadProxies() async {
    setState(() => _loadingProxies = true);
    try {
      final res = await ApiService.get('/proxies');
      if (res['success'] == true && mounted) {
        setState(() {
          _proxies = (res['data'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          _selectedProxyId = res['selectedProxyId'] as String?;
          _loadingProxies = false;
        });
      } else {
        setState(() => _loadingProxies = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingProxies = false);
    }
  }

  void _selectProxy(String? proxyId) {
    setState(() => _selectedProxyId = proxyId);
  }

  void _reset() {
    if (!mounted) return;
    setState(() {
      _phase = _RPhase.platform;
      _log.clear();
      _game = null;
      _platform = null;
      _events = [];
      _gaidCtrl.clear();
      _afUidCtrl.clear();
      _selectedEvent = null;
      _customLevel = false;
      _customLevelCtrl.clear();
      _resultOk = false;
      _resultMsg = '';
      _resultHttp = null;
    });
    _loadDailyUsage();
  }

  void _onPlatformSelected(String platform) {
    setState(() {
      _platform = platform;
      _phase = _RPhase.game;
    });
  }

  Future<void> _onGameSelected(Map<String, dynamic> item) async {
    setState(() => _phase = _RPhase.loadingDetail);
    _log$('جاري تحميل بيانات اللعبة: ${item['displayName'] ?? item['name']}...');
    final detail = await resolveRemoteGameDetail(item, _platform!);
    if (!mounted) return;
    if (detail == null) {
      _log$('تعذر تحميل بيانات اللعبة');
      setState(() => _phase = _RPhase.game);
      _showSnack('تعذر تحميل بيانات اللعبة');
      return;
    }
    _game = detail;
    _events = (detail['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    _selectedEvent = _events.isNotEmpty ? _events.first : null;
    _customLevel = false;
    _log$('اللعبة: ${detail['displayName']} [${remotePlatformLabel(_platform)}]');
    _log$('${_events.length} حدث متاح');
    setState(() => _phase = _RPhase.pickEvent);
  }

  Future<void> _sendEvent() async {
    final game = _game!;
    final platform = _platform!;

    final gaid = _gaidCtrl.text.trim();
    final afUid = _afUidCtrl.text.trim();

    if (gaid.isEmpty) {
      _showSnack('أدخل GAID يدوياً أولاً');
      return;
    }
    if (platform == 'af' && afUid.isEmpty) {
      _showSnack('أدخل AF UID يدوياً أولاً');
      return;
    }

    String eventName = '';
    String eventToken = '';

    if (_customLevel) {
      final lvlStr = _customLevelCtrl.text.trim();
      final lvl = int.tryParse(lvlStr);
      if (lvl == null || lvl <= 0) {
        _showSnack('أدخل رقم لفل صحيح (مثال: 5)');
        return;
      }
      eventName = _buildCustomLevelEvent(game, platform, lvl);
      eventToken = _buildCustomLevelToken(game, platform, lvl);
      _log$('لفل مخصص: $eventName');
    } else {
      if (_selectedEvent == null) { _showSnack('اختر حدثاً أولاً'); return; }
      eventName = _selectedEvent!['eventName'] as String? ?? '';
      eventToken = _selectedEvent!['eventToken'] as String? ?? '';
    }

    setState(() { _phase = _RPhase.sending; });
    _log$('إرسال: $eventName...');

    final body = <String, dynamic>{ 'platform': platform, 'gaid': gaid };
    if (afUid.isNotEmpty) body['afUid'] = afUid;

    switch (platform) {
      case 'af':
        body['package'] = game['package'];
        body['devKey'] = game['devKey'];
        body['eventName'] = eventName;
      case 'adj':
        body['appToken'] = game['appToken'];
        body['eventToken'] = eventToken.isNotEmpty ? eventToken : eventName;
      case 'singular':
        body['package'] = game['package'];
        body['appKey'] = game['appKey'];
        body['eventName'] = eventName;
    }

    try {
      final res = await ApiService.post('/games/send-event', body);
      final sc = res['_statusCode'] as int? ?? res['statusCode'] as int? ?? 0;
      final code = res['code'] as String? ?? '';

      if (sc == 403 || sc == 401 || sc == 429) {
        String msg;
        if (code == 'NO_SUBSCRIPTION') msg = 'لا يوجد اشتراك نشط. اشترك في باقة أولاً.';
        else if (code == 'DAILY_LIMIT_EXCEEDED') msg = 'وصلت للحد اليومي (${res['limit']} عملية). حاول غداً.';
        else msg = 'خطأ مصادقة. يرجى إعادة تسجيل الدخول.';
        _log$(msg);
        setState(() { _phase = _RPhase.pickEvent; });
        _showSnack(msg);
        return;
      }

      if (code == 'PROXY_NOT_WORKING' || sc == 502) {
        final msg = res['message']?.toString() ?? 'البروكسي المختار لا يعمل';
        _log$(msg);
        setState(() { _phase = _RPhase.pickEvent; });
        _showSnack(msg);
        return;
      }

      final ok = res['success'] == true;
      final httpCode = res['statusCode'] as int? ?? sc;
      _log$(ok ? 'نجح الإرسال - HTTP $httpCode' : 'فشل: ${res['message'] ?? 'خطأ'}');

      if (ok) {
        final usage = res['dailyUsage'] as Map<String, dynamic>?;
        final remaining = usage?['remaining'];
        if (remaining != null) _log$('عمليات متبقية اليوم: $remaining');
      }

      await _loadDailyUsage();
      setState(() {
        _phase = _RPhase.done;
        _resultOk = ok;
        _resultMsg = ok ? 'تم إرسال الحدث بنجاح!' : 'فشل الإرسال';
        _resultHttp = httpCode;
      });
    } catch (e) {
      _log$('خطأ شبكة: $e');
      setState(() { _phase = _RPhase.pickEvent; });
    }
  }

  String _buildCustomLevelEvent(Map<String, dynamic> game, String platform, int level) {
    final events = (game['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final lvEvent = events.firstWhere(
      (e) => (e['eventType'] ?? '').toString().toLowerCase().contains('level') ||
             (e['eventName'] ?? '').toString().contains(RegExp(r'\d')),
      orElse: () => <String, dynamic>{},
    );

    if (lvEvent.isNotEmpty) {
      final name = (lvEvent['eventName'] as String? ?? '');
      if (name.contains(RegExp(r'\d+'))) {
        return name.replaceFirst(RegExp(r'\d+'), '$level');
      }
      return '$name$level';
    }

    return platform == 'singular' ? 'sng_level_achieved_$level' : 'level_$level';
  }

  String _buildCustomLevelToken(Map<String, dynamic> game, String platform, int level) {
    if (platform != 'adj') return '';
    final events = (game['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (events.isNotEmpty) {
      return events.first['eventToken'] as String? ?? '';
    }
    return '';
  }

  String _masked(String s) {
    if (s.length <= 8) return s;
    return '${s.substring(0, 8)}...';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: AppTheme.cardBg, behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          _build3DLogo(28),
          const SizedBox(width: 10),
          const Text('جمبرة عن بعد', style: TextStyle(
            fontFamily: 'Cairo', fontWeight: FontWeight.bold,
            fontSize: 18, color: AppTheme.textPrimary,
          )),
        ]),
        actions: [
          if (_phase != _RPhase.platform && _phase != _RPhase.loadingDetail)
            IconButton(
              icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
              tooltip: 'بدء من جديد',
              onPressed: _reset,
            ),
        ],
      ),
      body: Column(children: [
        if (_dailyUsage != null) _buildUsageBar(),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _buildPhaseContent(),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 18),
              _buildTerminal(),
            ],
          ]),
        )),
      ]),
    );
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
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.diamond_outlined, size: size * 0.5, color: AppTheme.primary),
              Padding(
                padding: EdgeInsets.only(top: size * 0.15),
                child: Text('VIP', style: TextStyle(
                  fontSize: size * 0.18, fontWeight: FontWeight.w900,
                  color: Colors.black, letterSpacing: 1,
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseContent() {
    switch (_phase) {
      case _RPhase.platform:
        return RemotePlatformPicker(onSelected: _onPlatformSelected);
      case _RPhase.game:
        return RemoteGamePicker(platform: _platform!, onSelected: _onGameSelected);
      case _RPhase.loadingDetail:
        return _buildSpinner('جاري تحميل بيانات اللعبة...', 'يرجى الانتظار');
      case _RPhase.pickEvent:
        return _buildEventPicker();
      case _RPhase.sending:
        return _buildSpinner('إرسال الحدث...', 'يرجى الانتظار');
      case _RPhase.done:
        return _buildDoneCard();
    }
  }

  Widget _buildUsageBar() {
    final d = _dailyUsage!;
    if (d['hasSubscription'] != true) {
      return _infoBar(
        color: AppTheme.error,
        icon: Icons.warning_amber_outlined,
        text: 'لا يوجد اشتراك نشط — اشترك في باقة للمتابعة',
      );
    }
    final used = (d['used'] as num?)?.toInt() ?? 0;
    final limit = (d['limit'] as num?)?.toInt() ?? 1;
    final remaining = (d['remaining'] as num?)?.toInt() ?? 0;
    final progress = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    final barColor = remaining == 0
        ? AppTheme.error
        : remaining < (limit * 0.2) ? AppTheme.warning : AppTheme.success;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        Row(children: [
          Icon(Icons.bolt, color: barColor, size: 15),
          const SizedBox(width: 6),
          Text(d['planName']?.toString() ?? 'باقتك',
              style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 12)),
          const Spacer(),
          Text('$used / $limit عملية',
              style: TextStyle(color: barColor, fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: AppTheme.border,
            valueColor: AlwaysStoppedAnimation(barColor),
            minHeight: 5,
          ),
        ),
      ]),
    );
  }

  Widget _infoBar({required Color color, required IconData icon, required String text}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color, fontFamily: 'Cairo', fontSize: 12))),
      ]),
    );
  }

  Widget _buildSpinner(String title, String sub) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        const CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 2.5),
        const SizedBox(height: 18),
        Text(title, textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 6),
        Text(sub, style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 12)),
      ]),
    );
  }

  Widget _buildEventPicker() {
    final game = _game!;
    final platform = _platform ?? '';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF1A1A1A), Color(0xFF0A0A0A)]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.primary.withOpacity(0.35)),
        ),
        child: Row(children: [
          Text(game['emoji'] ?? '🎮', style: const TextStyle(fontSize: 32)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(game['displayName'] ?? '',
                style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 15)),
            const SizedBox(height: 5),
            Wrap(spacing: 6, children: [
              _badge(remotePlatformLabel(platform), AppTheme.primary),
              _badge('اختيار يدوي', AppTheme.warning),
            ]),
          ])),
        ]),
      ),
      const SizedBox(height: 12),

      _buildIdsSection(),
      const SizedBox(height: 12),

      _buildProxySection(),
      const SizedBox(height: 12),

      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bolt, color: AppTheme.primary, size: 17),
            const SizedBox(width: 8),
            const Text('اختر الحدث',
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 15)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppTheme.surfaceVariant, borderRadius: BorderRadius.circular(8)),
              child: Text('${_events.length} حدث', style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 11)),
            ),
          ]),
          const SizedBox(height: 12),
          ..._events.map((ev) => _buildEventTile(ev)),
          _buildCustomLevelTile(),
        ]),
      ),
      const SizedBox(height: 16),

      ElevatedButton.icon(
        onPressed: _sendEvent,
        icon: const Icon(Icons.send_rounded, size: 20, color: Colors.black),
        label: const Text('إرسال الحدث', style: TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ]);
  }

  Widget _buildIdsSection() {
    final isAdj = _platform == 'adj';
    final idLabel = isAdj ? 'GPS ADID' : 'GAID';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.fingerprint, color: AppTheme.primary, size: 17),
          const SizedBox(width: 8),
          const Text('أدخل معرفات الجهاز يدوياً',
              style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 14)),
        ]),
        const SizedBox(height: 10),
        _manualField(controller: _gaidCtrl, hint: 'أدخل $idLabel (مطلوب)', label: idLabel),
        if (_platform == 'af' || _platform == 'singular') ...[
          const SizedBox(height: 8),
          _manualField(
            controller: _afUidCtrl,
            hint: _platform == 'af' ? 'أدخل AF UID (مطلوب)' : 'أدخل AF UID (اختياري)',
            label: 'AF UID',
          ),
        ],
      ]),
    );
  }

  Widget _manualField({required TextEditingController controller, required String hint, required String label}) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppTheme.textHint, fontSize: 12, fontFamily: 'Cairo'),
        labelText: label,
        labelStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontFamily: 'Cairo'),
        filled: true,
        fillColor: AppTheme.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
    );
  }

  Widget _buildProxySection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.public, color: AppTheme.primary, size: 17),
          const SizedBox(width: 8),
          const Expanded(child: Text('البروكسي',
              style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 14))),
          if (_loadingProxies)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary)),
        ]),
        const SizedBox(height: 10),
        if (!_loadingProxies) ...[
          // Direct connection option
          GestureDetector(
            onTap: () => _selectProxy(null),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _selectedProxyId == null ? AppTheme.primary.withOpacity(0.12) : AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _selectedProxyId == null ? AppTheme.primary : AppTheme.border,
                  width: _selectedProxyId == null ? 1.5 : 1,
                ),
              ),
              child: Row(children: [
                Icon(_selectedProxyId == null ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: _selectedProxyId == null ? AppTheme.primary : AppTheme.textHint, size: 18),
                const SizedBox(width: 10),
                const Expanded(child: Text('اتصال مباشر (بدون بروكسي)',
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppTheme.textPrimary))),
              ]),
            ),
          ),
          if (_proxies.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._proxies.map((p) => _buildProxyTile(p)),
          ],
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/proxy-manager').then((_) => _loadProxies()),
            icon: const Icon(Icons.add, color: AppTheme.primary, size: 16),
            label: const Text('إدارة البروكسيات', style: TextStyle(color: AppTheme.primary, fontFamily: 'Cairo', fontSize: 12)),
          ),
        ],
      ]),
    );
  }

  Widget _buildProxyTile(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final name = p['name']?.toString() ?? '';
    final type = p['type']?.toString() ?? 'socks5';
    final host = p['host']?.toString() ?? '';
    final port = p['port']?.toString() ?? '';
    final isWorking = p['isWorking'] == true;
    final isSelected = _selectedProxyId == id;

    return GestureDetector(
      onTap: () => _selectProxy(id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary.withOpacity(0.12) : AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? AppTheme.primary : AppTheme.textHint, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(name, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: isSelected ? AppTheme.primary : AppTheme.textPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: (isWorking ? AppTheme.success : AppTheme.error).withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                child: Text(isWorking ? 'يعمل' : 'لا يعمل', style: TextStyle(color: isWorking ? AppTheme.success : AppTheme.error, fontSize: 9, fontFamily: 'Cairo')),
              ),
            ]),
            Text('$type · $host:$port', style: const TextStyle(color: AppTheme.textHint, fontSize: 10, fontFamily: 'monospace')),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: AppTheme.surfaceVariant, borderRadius: BorderRadius.circular(4)),
            child: Text(type.toUpperCase(), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 9)),
          ),
        ]),
      ),
    );
  }

  Widget _buildEventTile(Map<String, dynamic> ev) {
    final selected = !_customLevel && _selectedEvent?['eventName'] == ev['eventName'];
    return GestureDetector(
      onTap: () => setState(() { _selectedEvent = ev; _customLevel = false; }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary.withOpacity(0.14) : AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppTheme.primary : AppTheme.border, width: selected ? 1.5 : 1),
        ),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? AppTheme.primary : AppTheme.textHint, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ev['displayName'] ?? ev['eventName'] ?? '',
                style: TextStyle(
                  fontFamily: 'Cairo', fontSize: 13,
                  color: selected ? AppTheme.primary : AppTheme.textPrimary,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                )),
            Text(ev['eventName'] ?? '', style: const TextStyle(color: AppTheme.textHint, fontSize: 10, fontFamily: 'monospace')),
          ])),
        ]),
      ),
    );
  }

  Widget _buildCustomLevelTile() {
    return GestureDetector(
      onTap: () => setState(() { _customLevel = true; _selectedEvent = null; }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: _customLevel ? AppTheme.primary.withOpacity(0.12) : AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _customLevel ? AppTheme.primary : AppTheme.border, width: _customLevel ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_customLevel ? Icons.radio_button_checked : Icons.radio_button_off,
                color: _customLevel ? AppTheme.primary : AppTheme.textHint, size: 18),
            const SizedBox(width: 10),
            const Text('لفل مخصص', style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
            const SizedBox(width: 6),
            const Text('أدخل رقم اللفل', style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppTheme.textHint)),
          ]),
          if (_customLevel) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _customLevelCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: 'مثال: 5',
                hintStyle: const TextStyle(color: AppTheme.textHint, fontSize: 16),
                filled: true,
                fillColor: AppTheme.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.primary)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.primary)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.primary, width: 2)),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                isDense: true,
                suffixIcon: const Padding(padding: EdgeInsets.all(12), child: Text('Level', style: TextStyle(color: AppTheme.textHint, fontSize: 11))),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _customLevelCtrl,
              builder: (_, val, __) {
                final lvl = int.tryParse(val.text.trim().isEmpty ? '0' : val.text.trim()) ?? 0;
                if (lvl <= 0) return const SizedBox.shrink();
                final preview = _buildCustomLevelEvent(_game!, _platform ?? '', lvl);
                return Text('سيُرسل: $preview', style: const TextStyle(color: AppTheme.textHint, fontSize: 11, fontFamily: 'monospace'));
              },
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildDoneCard() {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF1A1A1A), Color(0xFF0A0A0A)]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: (_resultOk ? AppTheme.success : AppTheme.error).withOpacity(0.4)),
        ),
        child: Column(children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(shape: BoxShape.circle, color: (_resultOk ? AppTheme.success : AppTheme.error).withOpacity(0.12)),
            child: Icon(_resultOk ? Icons.check_circle_outline : Icons.error_outline, color: _resultOk ? AppTheme.success : AppTheme.error, size: 38),
          ),
          const SizedBox(height: 16),
          Text(_resultMsg, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, fontFamily: 'Cairo', color: _resultOk ? AppTheme.success : AppTheme.error)),
          if (_resultHttp != null) ...[
            const SizedBox(height: 6),
            Text('HTTP $_resultHttp', style: const TextStyle(color: AppTheme.textHint, fontFamily: 'monospace', fontSize: 12)),
          ],
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => setState(() { _phase = _RPhase.pickEvent; }),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: const BorderSide(color: AppTheme.primary),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('إرسال مجدداً', style: TextStyle(fontFamily: 'Cairo', fontSize: 13)),
            )),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(
              onPressed: _reset,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('لعبة جديدة', style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.black)),
            )),
          ]),
        ]),
      ),
    ]);
  }

  Widget _buildTerminal() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF050505), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.error.withOpacity(0.7))),
            const SizedBox(width: 6),
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.warning.withOpacity(0.7))),
            const SizedBox(width: 6),
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.success.withOpacity(0.7))),
            const SizedBox(width: 10),
            const Text('سجل العمليات', style: TextStyle(color: AppTheme.textHint, fontSize: 11, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 10),
          ..._log.map((line) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: const TextStyle(color: Color(0xFF7FD9A0), fontFamily: 'monospace', fontSize: 11, height: 1.45)),
          )),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.4))),
      child: Text(text, style: TextStyle(color: color, fontSize: 10, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
    );
  }
}
