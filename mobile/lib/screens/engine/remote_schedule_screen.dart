// ── جدولة عمليات عن بعد (Remote Schedule Operations) ─────────────────────────
// Manual/remote twin of schedule_engine_screen.dart. Same plan-input, confirm,
// running/polling, and "my groups" UI + logic (reusing the exact /schedule/*
// endpoints), but platform + game are chosen manually from the catalog
// instead of being auto-detected, and identifiers are always entered by
// hand. This file is purely additive.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import 'remote_common.dart';

enum _RSPhase {
  platform,
  game,
  loadingDetail,
  inputPlan,
  confirm,
  running,
  myGroups,
}

class RemoteScheduleScreen extends StatefulWidget {
  const RemoteScheduleScreen({super.key});
  @override
  State<RemoteScheduleScreen> createState() => _RemoteScheduleScreenState();
}

class _RemoteScheduleScreenState extends State<RemoteScheduleScreen> with SingleTickerProviderStateMixin {
  _RSPhase _phase = _RSPhase.platform;
  final List<String> _log = [];

  Map<String, dynamic>? _game;
  String? _platform;

  final _gaidCtrl = TextEditingController();
  final _afUidCtrl = TextEditingController();
  final _levelsCtrl = TextEditingController();

  List<Map<String, dynamic>> _parsedEntries = [];
  List<String> _parseErrors = [];

  Map<String, dynamic>? _createdGroup;
  Timer? _pollTimer;

  late final AnimationController _logoCtrl;

  @override
  void initState() {
    super.initState();
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  }

  @override
  void dispose() {
    _gaidCtrl.dispose();
    _afUidCtrl.dispose();
    _levelsCtrl.dispose();
    _pollTimer?.cancel();
    _logoCtrl.dispose();
    super.dispose();
  }

  void _log$(String msg) {
    if (!mounted) return;
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    setState(() => _log.add('[$ts] $msg'));
  }

  void _reset() {
    if (!mounted) return;
    _pollTimer?.cancel();
    setState(() {
      _phase = _RSPhase.platform;
      _log.clear();
      _game = null;
      _platform = null;
      _parsedEntries = [];
      _parseErrors = [];
      _createdGroup = null;
      _levelsCtrl.clear();
      _gaidCtrl.clear();
      _afUidCtrl.clear();
    });
  }

  void _onPlatformSelected(String platform) {
    setState(() {
      _platform = platform;
      _phase = _RSPhase.game;
    });
  }

  Future<void> _onGameSelected(Map<String, dynamic> item) async {
    setState(() => _phase = _RSPhase.loadingDetail);
    _log$('جاري تحميل بيانات اللعبة: ${item['displayName'] ?? item['name']}...');
    final detail = await resolveRemoteGameDetail(item, _platform!);
    if (!mounted) return;
    if (detail == null) {
      _log$('تعذر تحميل بيانات اللعبة');
      setState(() => _phase = _RSPhase.game);
      _showSnack('تعذر تحميل بيانات اللعبة');
      return;
    }
    _game = detail;
    _log$('اللعبة: ${detail['displayName']} [${remotePlatformLabel(_platform)}]');
    setState(() => _phase = _RSPhase.inputPlan);
  }

  Future<void> _validateAndConfirm() async {
    final lines = _levelsCtrl.text.trim();
    if (lines.isEmpty) {
      _showSnack('أدخل اللفلات/التوكنات أولاً');
      return;
    }

    final gaid = _gaidCtrl.text.trim();
    if (gaid.isEmpty) {
      _showSnack('أدخل GAID يدوياً أولاً');
      return;
    }
    if (_platform == 'af' || _platform == 'singular') {
      final afUid = _afUidCtrl.text.trim();
      if (_platform == 'af' && afUid.isEmpty) {
        _showSnack('أدخل AF UID يدوياً أولاً');
        return;
      }
    }

    _log$('التحقق من الصيغة...');
    final res = await ApiService.post('/schedule/parse-levels', {
      'platform': _platform,
      'lines': lines,
    });

    if (res['success'] == true) {
      _parsedEntries = (res['entries'] as List).cast<Map<String, dynamic>>();
      _log$('${_parsedEntries.length} إدخال صالح');
      setState(() => _phase = _RSPhase.confirm);
    } else {
      final errors = (res['errors'] as List?)?.cast<String>() ?? [];
      _parseErrors = errors;
      _log$('أخطاء: ${errors.length}');
      _showSnack(res['message'] ?? 'خطأ في الصيغة');
    }
  }

  Future<void> _confirmAndStart() async {
    final gaid = _gaidCtrl.text.trim();
    final afUid = _afUidCtrl.text.trim();

    final game = _game!;
    final platform = _platform!;

    final body = <String, dynamic>{
      'platform': platform,
      'gameName': game['displayName'] ?? game['name'] ?? '',
      'gameId': game['id'],
      'eventsOrder': _parsedEntries,
      'intervalMinutes': -1,
      'gaid': gaid,
    };

    if (afUid.isNotEmpty) body['afUid'] = afUid;

    switch (platform) {
      case 'af':
        body['gamePkg'] = game['package'];
        body['gameKey'] = game['devKey'];
        break;
      case 'singular':
        body['gamePkg'] = game['package'];
        body['gameKey'] = game['appKey'];
        break;
      case 'adj':
        body['gameKey'] = game['appToken'];
        break;
    }

    setState(() => _phase = _RSPhase.running);
    _log$('إنشاء مجموعة الجدولة...');

    final res = await ApiService.post('/schedule/create', body);
    if (res['success'] == true) {
      _createdGroup = { 'id': res['groupId'], 'status': 'active' };
      _log$('✅ تم تفعيل الجدولة! معرف: ${res['groupId']}');
      _log$('🚀 يبدأ الإرسال الآن...');
      _pollStatus();
    } else {
      _log$('فشل: ${res['message'] ?? 'خطأ'}');
      setState(() => _phase = _RSPhase.confirm);
      _showSnack(res['message'] ?? 'فشل إنشاء الجدولة');
    }
  }

  void _pollStatus() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_createdGroup == null) return;
      final res = await ApiService.get('/schedule/${_createdGroup!['id']}');
      if (res['success'] == true) {
        final group = res['group'] as Map<String, dynamic>?;
        final status = group?['status'] as String? ?? '';
        if (status != 'active' && mounted) {
          _pollTimer?.cancel();
          _log$('انتهت الجدولة: $status');
          setState(() => _createdGroup!['status'] = status);
        }
      }
    });
  }

  Future<void> _stopCurrent() async {
    if (_createdGroup == null) return;
    _log$('إيقاف الجدولة...');
    await ApiService.post('/schedule/${_createdGroup!['id']}/stop', {});
    _pollTimer?.cancel();
    if (mounted) {
      setState(() => _createdGroup!['status'] = 'stopped');
      _log$('تم الإيقاف');
    }
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
          const Text('جدولة عمليات عن بعد', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textPrimary)),
        ]),
        actions: [
          if (_phase != _RSPhase.platform && _phase != _RSPhase.game && _phase != _RSPhase.loadingDetail)
            IconButton(icon: const Icon(Icons.refresh, color: AppTheme.textSecondary), tooltip: 'بدء من جديد', onPressed: _reset),
        ],
      ),
      body: Column(children: [
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
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF333333), Color(0xFF0A0A0A)]),
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
            Padding(padding: EdgeInsets.only(top: size * 0.15), child: Text('VIP', style: TextStyle(fontSize: size * 0.18, fontWeight: FontWeight.w900, color: Colors.black, letterSpacing: 1))),
          ]),
        ),
      ),
    );
  }

  Widget _buildPhaseContent() {
    switch (_phase) {
      case _RSPhase.platform:
        return _buildPlatformWithGroupsButton();
      case _RSPhase.game:
        return RemoteGamePicker(platform: _platform!, onSelected: _onGameSelected);
      case _RSPhase.loadingDetail:
        return _buildSpinner('جاري تحميل بيانات اللعبة...', 'يرجى الانتظار');
      case _RSPhase.inputPlan:
        return _buildPlanInput();
      case _RSPhase.confirm:
        return _buildConfirmCard();
      case _RSPhase.running:
        return _buildRunningCard();
      case _RSPhase.myGroups:
        return _RemoteMyGroupsView(onBack: () => setState(() => _phase = _RSPhase.platform));
    }
  }

  Widget _buildPlatformWithGroupsButton() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RemotePlatformPicker(onSelected: _onPlatformSelected),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => setState(() => _phase = _RSPhase.myGroups),
          icon: const Icon(Icons.list_alt, color: AppTheme.textSecondary, size: 18),
          label: const Text('مجموعاتي', style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppTheme.textSecondary)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.border),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    ]);
  }

  Widget _buildSpinner(String title, String sub) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        const CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 2.5),
        const SizedBox(height: 18),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 6),
        Text(sub, style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 12)),
      ]),
    );
  }

  Widget _buildPlanInput() {
    final game = _game!;
    final platform = _platform ?? '';

    final isAdj = platform == 'adj';
    final exampleLines = isAdj
        ? 'gdhdhhd/0.5h\nabc123x/2h\ntok789z/1d\ntknfast/30m'
        : '17/2h\n18/0.5h\n19/1d\n20/30m';
    final idLabel = isAdj ? 'GPS ADID' : 'GAID';

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
            Text(game['displayName'] ?? '', style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 15)),
            const SizedBox(height: 5),
            Wrap(spacing: 6, children: [
              _badge(remotePlatformLabel(platform), AppTheme.primary),
              _badge('اختيار يدوي', AppTheme.warning),
            ]),
          ])),
        ]),
      ),
      const SizedBox(height: 12),

      _buildIdsSection(idLabel: idLabel),
      const SizedBox(height: 12),

      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.schedule, color: AppTheme.primary, size: 17),
            const SizedBox(width: 8),
            Text(isAdj ? 'أدخل التوكنات مع التوقيت المطلق' : 'أدخل اللفلات مع التوقيت المطلق',
                style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 15)),
          ]),
          const SizedBox(height: 8),
          Text(
            isAdj ? 'كل سطر: token/وقت — التوقيت مطلق من لحظة البدء' : 'كل سطر: رقم_لفل/وقت — التوقيت مطلق من لحظة البدء',
            style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 12),
          ),
          const SizedBox(height: 4),
          const Text(
            'صيغ الوقت: 1h ساعة · 0.5h نصف ساعة · 30m دقيقة · 30s ثانية · 1d يوم · 0 فوري',
            style: TextStyle(color: AppTheme.textHint, fontFamily: 'Cairo', fontSize: 11),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _levelsCtrl,
            maxLines: 6,
            style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              hintText: exampleLines,
              hintStyle: const TextStyle(color: AppTheme.textHint, fontSize: 12, fontFamily: 'monospace'),
              filled: true,
              fillColor: AppTheme.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.primary)),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          if (_parseErrors.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.error.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.error.withOpacity(0.3))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _parseErrors.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(e, style: const TextStyle(color: AppTheme.error, fontFamily: 'Cairo', fontSize: 11)),
              )).toList()),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 16),

      ElevatedButton.icon(
        onPressed: _validateAndConfirm,
        icon: const Icon(Icons.check_circle_outline, size: 20, color: Colors.black),
        label: const Text('تحقق ومتابعة', style: TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ]);
  }

  Widget _buildIdsSection({required String idLabel}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.fingerprint, color: AppTheme.primary, size: 17),
          const SizedBox(width: 8),
          const Text('أدخل معرفات الجهاز يدوياً', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 14)),
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

  Widget _buildConfirmCard() {
    final game = _game!;
    final platform = _platform ?? '';
    final entries = _parsedEntries;

    String fmtInterval(double m) {
      if (m == 0) return 'فوري';
      if (m < 60) return m == m.toInt() ? '${m.toInt()}د' : '${m.toStringAsFixed(1)}د';
      final h = m / 60;
      return h == h.toInt() ? '${h.toInt()}س' : '${h.toStringAsFixed(1)}س';
    }

    String entryLabel(Map<String, dynamic> e) {
      final t = fmtInterval((e['interval'] as num).toDouble());
      if (e.containsKey('token')) return 'TOKEN:${e['token']} ← في T+$t';
      return 'LV${e['level']} ← في T+$t';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF1A1A1A), Color(0xFF0A0A0A)]),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('تفاصيل الخطة', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 16)),
          const SizedBox(height: 14),
          _detailRow('المنصة', platform.toUpperCase()),
          _detailRow('اللعبة', game['displayName'] ?? ''),
          const SizedBox(height: 8),
          const Text('اللفلات بالترتيب:', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 6),
          ...entries.asMap().entries.map((me) => Padding(
            padding: const EdgeInsets.only(bottom: 4, right: 8),
            child: Text('${me.key + 1}. ${entryLabel(me.value)}', style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'monospace', fontSize: 12)),
          )),
          const SizedBox(height: 10),
          _detailRow('الفاصل', 'توقيت مطلق من لحظة البدء'),
          _detailRow('GAID', _masked(_gaidCtrl.text.trim())),
          if (_platform == 'af' || _platform == 'singular')
            _detailRow('AF UID', _masked(_afUidCtrl.text.trim())),
        ]),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: OutlinedButton(
          onPressed: () => setState(() => _phase = _RSPhase.inputPlan),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.textSecondary,
            side: const BorderSide(color: AppTheme.border),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('تعديل', style: TextStyle(fontFamily: 'Cairo', fontSize: 14)),
        )),
        const SizedBox(width: 10),
        Expanded(child: ElevatedButton(
          onPressed: _confirmAndStart,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('تأكيد وتشغيل', style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: Colors.black)),
        )),
      ]),
    ]);
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 13)),
        Expanded(child: Text(value, style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'monospace', fontSize: 12))),
      ]),
    );
  }

  Widget _buildRunningCard() {
    final status = _createdGroup?['status'] as String? ?? 'active';
    final isRunning = status == 'active';
    final isCompleted = status == 'completed';

    return Column(children: [
      Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF1A1A1A), Color(0xFF0A0A0A)]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: (isCompleted ? AppTheme.success : isRunning ? AppTheme.warning : AppTheme.error).withOpacity(0.4)),
        ),
        child: Column(children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(shape: BoxShape.circle, color: (isCompleted ? AppTheme.success : isRunning ? AppTheme.warning : AppTheme.error).withOpacity(0.12)),
            child: Icon(
              isCompleted ? Icons.check_circle_outline : isRunning ? Icons.schedule : Icons.stop_circle_outlined,
              color: isCompleted ? AppTheme.success : isRunning ? AppTheme.warning : AppTheme.error,
              size: 38,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isCompleted ? 'تم اكتمال جميع المهام!' : isRunning ? 'الجدولة تعمل الآن...' : 'تم إيقاف الجدولة',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, fontFamily: 'Cairo', color: isCompleted ? AppTheme.success : isRunning ? AppTheme.warning : AppTheme.error),
          ),
          const SizedBox(height: 6),
          Text('معرف المجموعة: ${_createdGroup?['id']?.toString().substring(0, 8) ?? ''}', style: const TextStyle(color: AppTheme.textHint, fontFamily: 'monospace', fontSize: 11)),
          const SizedBox(height: 22),
          if (isRunning)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _stopCurrent,
                icon: const Icon(Icons.stop, color: AppTheme.error, size: 18),
                label: const Text('إيقاف الجدولة', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.error, fontSize: 14)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppTheme.error.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          if (!isRunning) ...[
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: _reset,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  side: const BorderSide(color: AppTheme.primary),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('جدولة جديدة', style: TextStyle(fontFamily: 'Cairo', fontSize: 13)),
              )),
            ]),
          ],
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

// ── My Groups view (duplicated privately, matching schedule_engine_screen.dart's
// _MyGroupsView, to keep the two flows fully isolated per the "don't touch the
// existing flow" requirement) ────────────────────────────────────────────────

class _RemoteMyGroupsView extends StatefulWidget {
  final VoidCallback onBack;
  const _RemoteMyGroupsView({required this.onBack});
  @override
  State<_RemoteMyGroupsView> createState() => _RemoteMyGroupsViewState();
}

class _RemoteMyGroupsViewState extends State<_RemoteMyGroupsView> {
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await ApiService.get('/schedule/list');
      if (res['success'] == true) {
        _groups = (res['groups'] as List).cast<Map<String, dynamic>>();
      } else {
        _error = res['message'] ?? 'فشل التحميل';
      }
    } catch (e) {
      _error = 'خطأ: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _stop(String id) async {
    await ApiService.post('/schedule/$id/stop', {});
    _load();
  }

  Future<void> _activate(String id) async {
    await ApiService.post('/schedule/$id/activate', {});
    _load();
  }

  Future<void> _delete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('تأكيد الحذف', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textPrimary)),
        content: const Text('هل تريد حذف هذه المجموعة؟', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.error))),
        ],
      ),
    );
    if (confirmed == true) {
      await ApiService.delete('/schedule/$id');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: AppTheme.primary)));
    }

    final backButton = Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: widget.onBack,
        icon: const Icon(Icons.arrow_forward, size: 16, color: AppTheme.textSecondary),
        label: const Text('رجوع', style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textSecondary, fontSize: 13)),
      ),
    );

    if (_error != null) {
      return Column(children: [
        backButton,
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppTheme.error.withOpacity(0.1), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.error.withOpacity(0.3))),
          child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontFamily: 'Cairo')),
        ),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _load, child: const Text('إعادة', style: TextStyle(fontFamily: 'Cairo', color: Colors.black))),
      ]);
    }
    if (_groups.isEmpty) {
      return Column(children: [
        backButton,
        Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppTheme.border)),
          child: const Column(children: [
            Icon(Icons.inbox_outlined, color: AppTheme.textHint, size: 48),
            SizedBox(height: 12),
            Text('لا توجد مجموعات محفوظة', style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo')),
          ]),
        ),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      backButton,
      Row(children: [
        const Text('مجموعاتي', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 16)),
        const Spacer(),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: AppTheme.textSecondary, size: 18)),
      ]),
      const SizedBox(height: 8),
      ..._groups.map((g) => _groupCard(g)),
    ]);
  }

  Widget _groupCard(Map<String, dynamic> g) {
    final status = g['status'] as String? ?? '';
    final isActive = status == 'active';
    final statusColor = isActive ? AppTheme.success : AppTheme.textSecondary;
    final statusText = isActive ? 'نشطة' : status == 'completed' ? 'مكتملة' : 'متوقفة';

    List<dynamic> events = [];
    try { events = jsonDecode(g['eventsOrder'] as String) as List; } catch (_) {}

    final interval = (g['intervalMinutes'] as num?)?.toInt() ?? 0;
    final intervalText = interval == -1 ? 'مخصص' : interval == 0 ? 'فوري' : interval < 60 ? '$interval دقيقة' : '${interval ~/ 60} ساعة';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(g['gameName']?.toString() ?? '', style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 14)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: statusColor.withOpacity(0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: statusColor.withOpacity(0.4))),
            child: Text(statusText, style: TextStyle(color: statusColor, fontFamily: 'Cairo', fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('${(g['platform'] ?? '').toString().toUpperCase()} · $intervalText · ${events.length} حدث', style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 11)),
        const SizedBox(height: 10),
        Row(children: [
          if (isActive)
            Expanded(child: OutlinedButton(
              onPressed: () => _stop(g['id']),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.error,
                side: BorderSide(color: AppTheme.error.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('إيقاف', style: TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            ))
          else if (status != 'completed')
            Expanded(child: OutlinedButton(
              onPressed: () => _activate(g['id']),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.success,
                side: BorderSide(color: AppTheme.success.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('تفعيل', style: TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            )),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(
            onPressed: () => _delete(g['id']),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textSecondary,
              side: const BorderSide(color: AppTheme.border),
              padding: const EdgeInsets.symmetric(vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('حذف', style: TextStyle(fontFamily: 'Cairo', fontSize: 12)),
          )),
        ]),
      ]),
    );
  }
}
