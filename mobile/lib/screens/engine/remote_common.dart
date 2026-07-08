// ── Shared helpers for the "جمبرة عن بعد" (Remote Engine) feature ────────────
// Used by remote_jumper_screen.dart and remote_schedule_screen.dart.
// Provides: platform picker UI, game list fetch + picker sheet, and game
// detail resolution (static catalog vs admin-added DB games).
//
// This file is purely additive — it does not modify or replace any part of
// the existing on-device (auto-detect) engine flow.

import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';

const List<Map<String, String>> kRemotePlatforms = [
  {'value': 'af', 'label': 'AppsFlyer', 'emoji': '🚀'},
  {'value': 'adj', 'label': 'Adjust', 'emoji': '🎯'},
  {'value': 'singular', 'label': 'Singular', 'emoji': '📡'},
];

String remotePlatformLabel(String? p) {
  switch (p) {
    case 'af':
      return 'AppsFlyer';
    case 'singular':
      return 'Singular';
    case 'adj':
      return 'Adjust';
    default:
      return p ?? '';
  }
}

/// Fetches all games for a given platform (static catalog + admin-added DB
/// games) from `GET /games/list`. Each returned item is tagged with a
/// `_source` key: 'static' or 'db'.
Future<List<Map<String, dynamic>>> fetchRemoteGames(String platform) async {
  final res = await ApiService.get('/games/list', auth: false);
  if (res['success'] != true) return [];

  final List<Map<String, dynamic>> result = [];

  final staticList = (res[platform] as List?)?.cast<Map<String, dynamic>>() ?? [];
  for (final g in staticList) {
    result.add({...g, '_source': 'static'});
  }

  final dbList = (res['db'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  for (final g in dbList) {
    if (g['platform'] == platform) {
      result.add({...g, '_source': 'db'});
    }
  }

  return result;
}

/// Resolves full game detail (events + platform keys) for a game item
/// returned by [fetchRemoteGames]. DB games already carry full detail from
/// `/games/list`; static games need a lookup by name via `/games/detail`.
Future<Map<String, dynamic>?> resolveRemoteGameDetail(
  Map<String, dynamic> item,
  String platform,
) async {
  if (item['_source'] == 'db') {
    return item;
  }
  final res = await ApiService.get(
    '/games/detail?platform=${Uri.encodeComponent(platform)}&source=static&name=${Uri.encodeComponent(item['name'] ?? '')}',
    auth: false,
  );
  if (res['success'] == true && res['found'] == true) {
    return res['game'] as Map<String, dynamic>?;
  }
  return null;
}

// ── Platform picker card grid ────────────────────────────────────────────────

class RemotePlatformPicker extends StatelessWidget {
  final void Function(String platform) onSelected;
  const RemotePlatformPicker({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(30),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A1A), Color(0xFF0A0A0A)],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppTheme.glassBorder, width: 0.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 25, offset: const Offset(0, 10))],
        ),
        child: Column(children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [Color(0xFF333333), Color(0xFF0A0A0A)]),
              border: Border.all(color: AppTheme.primary.withOpacity(0.4), width: 1),
            ),
            child: const Center(child: Icon(Icons.satellite_alt_outlined, color: AppTheme.primary, size: 34)),
          ),
          const SizedBox(height: 20),
          const Text('اختر منصة التتبع', style: TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontFamily: 'Cairo',
          )),
          const SizedBox(height: 10),
          const Text(
            'اختر المنصة التي تعمل عليها اللعبة، ثم اختر اللعبة وأدخل المعرفات يدوياً',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo', fontSize: 13, height: 1.65),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      ...kRemotePlatforms.map((p) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onSelected(p['value']!),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(children: [
                Container(
                  width: 46, height: 46,
                  decoration: BoxDecoration(color: AppTheme.surfaceVariant, borderRadius: BorderRadius.circular(12)),
                  child: Center(child: Text(p['emoji']!, style: const TextStyle(fontSize: 22))),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(p['label']!, style: const TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textPrimary,
                ))),
                const Icon(Icons.arrow_forward_ios, size: 15, color: AppTheme.textSecondary),
              ]),
            ),
          ),
        ),
      )),
    ]);
  }
}

// ── Game picker (searchable list, loaded from /games/list) ─────────────────

class RemoteGamePicker extends StatefulWidget {
  final String platform;
  final void Function(Map<String, dynamic> gameItem) onSelected;
  const RemoteGamePicker({super.key, required this.platform, required this.onSelected});

  @override
  State<RemoteGamePicker> createState() => _RemoteGamePickerState();
}

class _RemoteGamePickerState extends State<RemoteGamePicker> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _games = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final games = await fetchRemoteGames(widget.platform);
      if (!mounted) return;
      setState(() { _games = games; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'خطأ: $e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _games
        : _games.where((g) {
            final name = (g['displayName'] ?? g['name'] ?? '').toString().toLowerCase();
            return name.contains(_query.toLowerCase());
          }).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          const Icon(Icons.videogame_asset_outlined, color: AppTheme.primary, size: 18),
          const SizedBox(width: 8),
          Text('اختر اللعبة — ${remotePlatformLabel(widget.platform)}', style: const TextStyle(
            fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: AppTheme.textPrimary, fontSize: 14,
          )),
        ]),
      ),
      const SizedBox(height: 10),
      TextField(
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'Cairo', fontSize: 13),
        decoration: InputDecoration(
          hintText: 'بحث عن لعبة...',
          hintStyle: const TextStyle(color: AppTheme.textHint, fontFamily: 'Cairo'),
          prefixIcon: const Icon(Icons.search, color: AppTheme.textHint, size: 18),
          filled: true,
          fillColor: AppTheme.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primary)),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          isDense: true,
        ),
      ),
      const SizedBox(height: 10),
      if (_loading)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        )
      else if (_error != null)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.error.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.error.withOpacity(0.3)),
          ),
          child: Column(children: [
            Text(_error!, style: const TextStyle(color: AppTheme.error, fontFamily: 'Cairo')),
            const SizedBox(height: 10),
            ElevatedButton(onPressed: _load, child: const Text('إعادة المحاولة', style: TextStyle(fontFamily: 'Cairo', color: Colors.black))),
          ]),
        )
      else if (filtered.isEmpty)
        Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.border),
          ),
          child: const Column(children: [
            Icon(Icons.inbox_outlined, color: AppTheme.textHint, size: 40),
            SizedBox(height: 10),
            Text('لا توجد ألعاب متاحة على هذه المنصة', style: TextStyle(color: AppTheme.textSecondary, fontFamily: 'Cairo')),
          ]),
        )
      else
        ...filtered.map((g) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => widget.onSelected(g),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(children: [
                  Text(g['emoji'] ?? '🎮', style: const TextStyle(fontSize: 26)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(g['displayName'] ?? g['name'] ?? '', style: const TextStyle(
                    fontFamily: 'Cairo', fontWeight: FontWeight.w600, color: AppTheme.textPrimary, fontSize: 13,
                  ))),
                  const Icon(Icons.arrow_forward_ios, size: 13, color: AppTheme.textSecondary),
                ]),
              ),
            ),
          ),
        )),
    ]);
  }
}
