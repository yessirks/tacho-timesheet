// Diary: what you did each day (places, drops, pickups, coupling, expenses). What you write here always wins over the tacho.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/tacho.dart' show Fix;
import '../core/week.dart';
import '../data/store.dart';
import 'common.dart';
import 'map_tab.dart' show starEditor;
import 'receipts.dart';

class DiaryTab extends StatefulWidget {
  final ValueNotifier<String> day; final void Function(String sunday) openWeek;
  const DiaryTab({super.key, required this.day, required this.openWeek});
  @override
  State<DiaryTab> createState() => _DiaryTabState();
}

class _DiaryTabState extends State<DiaryTab> {
  bool month = false;
  late String calMonth = widget.day.value.substring(0, 7);
  String get sel => widget.day.value;
  void select(String d) { widget.day.value = d; setState(() => calMonth = d.substring(0, 7)); }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([store, widget.day]), builder: (context, _) {
        final t = todayKey();
        final badge = sel == t ? 'Today' : sel == addDays(t, -1) ? 'Yesterday' : sel == addDays(t, 1) ? 'Tomorrow' : '';
        return Scaffold(
          appBar: AppBar(
            title: Text(month ? _monthTitle(calMonth) : _monthTitle(sel.substring(0, 7)), style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              TextButton(onPressed: () => select(todayKey()), child: const Text('Today', style: TextStyle(color: Colors.white))),
              IconButton(tooltip: month ? 'Week' : 'Month', icon: Icon(month ? Icons.view_week_outlined : Icons.calendar_month_outlined), onPressed: () => setState(() => month = !month)),
            ],
            bottom: PreferredSize(preferredSize: Size.fromHeight(month ? 0 : 74), child: month ? const SizedBox() : _WeekStrip(sel: sel, onPick: select)),
          ),
          body: GestureDetector(
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v.abs() > 350) select(addDays(sel, v < 0 ? 1 : -1));
            },
            child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
              if (month) _MonthGrid(month: calMonth, sel: sel, onPick: select, onMove: (n) {
                final (y, m, _) = parts('$calMonth-01');
                setState(() => calMonth = DateTime.utc(y, m + n, 1).toIso8601String().substring(0, 7));
              }),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                child: Row(children: [
                  IconButton(onPressed: () => select(addDays(sel, -1)), icon: const Icon(Icons.chevron_left)),
                  Expanded(child: Column(children: [
                    Text('${dayNames[dayIdx(sel)]} ${fmtLong(sel)}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    if (badge.isNotEmpty) Text(badge, style: const TextStyle(color: orange, fontWeight: FontWeight.w700)),
                  ])),
                  IconButton(onPressed: () => select(addDays(sel, 1)), icon: const Icon(Icons.chevron_right)),
                ]),
              ),
              _DayEditor(key: ValueKey(sel), date: sel, openWeek: widget.openWeek),
            ]),
          ),
        );
      });

  String _monthTitle(String ym) { final (y, m, _) = parts('$ym-01'); return '${monthNames[m - 1]} $y'; }
}

class _WeekStrip extends StatelessWidget {
  final String sel; final ValueChanged<String> onPick;
  const _WeekStrip({required this.sel, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final sun = sundayOfKey(sel), today = todayKey();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(children: [
        IconButton(color: Colors.white70, onPressed: () => onPick(addDays(sel, -7)), icon: const Icon(Icons.chevron_left)),
        for (var i = 0; i < 7; i++)
          Expanded(child: () {
            final d = addDays(sun, i), on = d == sel, e = store.dget(d);
            final has = store.stopsOn(d).any((s) => '${s['name'] ?? ''}${s['ref'] ?? ''}'.trim().isNotEmpty) || (e['start'] ?? '').toString().isNotEmpty || (e['finish'] ?? '').toString().isNotEmpty;
            return GestureDetector(
              onTap: () => onPick(d),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180), margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(color: on ? orange : Colors.white.withValues(alpha: .06), borderRadius: BorderRadius.circular(14),
                    border: d == today && !on ? Border.all(color: orange, width: 1.5) : null),
                child: Column(children: [
                  Text('SMTWTFS'[i], style: TextStyle(color: on ? Colors.white : Colors.white60, fontSize: 11, fontWeight: FontWeight.w700)),
                  Text('${int.parse(d.substring(8))}', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (store.tachoDay(d) != null) _dot(const Color(0xFF7FB2FF)),
                    if (has) _dot(Colors.white),
                    if (store.dayExpTotal(d) > 0) _dot(amber),
                  ]),
                ]),
              ),
            );
          }()),
        IconButton(color: Colors.white70, onPressed: () => onPick(addDays(sel, 7)), icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }
  Widget _dot(Color c) => Container(width: 5, height: 5, margin: const EdgeInsets.only(top: 3, left: 1, right: 1), decoration: BoxDecoration(color: c, shape: BoxShape.circle));
}

class _MonthGrid extends StatelessWidget {
  final String month, sel; final ValueChanged<String> onPick; final ValueChanged<int> onMove;
  const _MonthGrid({required this.month, required this.sel, required this.onPick, required this.onMove});
  @override
  Widget build(BuildContext context) {
    final (y, m, _) = parts('$month-01');
    final start = addDays('$month-01', -(DateTime.utc(y, m, 1).weekday % 7)), today = todayKey();
    final cs = Theme.of(context).colorScheme;
    final cells = <Widget>[];
    for (var i = 0; i < 42; i++) {
      final d = addDays(start, i);
      if (i == 35 && d.substring(0, 7) != month) break;
      final e = store.dget(d), r = store.tachoDay(d), cash = store.dayExpTotal(d);
      final s = (e['start'] ?? '').toString().isNotEmpty ? e['start'] : r != null ? store.fixLabel(r.startFix) : '';
      final f = (e['finish'] ?? '').toString().isNotEmpty ? e['finish'] : r != null ? store.fixLabel(r.endFix) : '';
      final stops = store.fmtStops(e['stops'] as List?);
      final line = [if ('$s$f'.isNotEmpty) '${'$s'.isEmpty ? '?' : s} → ${'$f'.isEmpty ? '?' : f}', if (stops.isNotEmpty) stops].join('\n');
      cells.add(InkWell(
        onTap: () => onPick(d),
        child: Container(
          margin: const EdgeInsets.all(1.5), padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: d == sel ? orange.withValues(alpha: .16) : cs.surface, borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d == today ? orange : cs.outlineVariant.withValues(alpha: .5), width: d == today ? 1.5 : 1),
          ),
          child: Opacity(opacity: d.substring(0, 7) == month ? 1 : .4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${int.parse(d.substring(8))}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              if (r != null) Container(width: 5, height: 5, margin: const EdgeInsets.only(left: 3), decoration: const BoxDecoration(color: Color(0xFF3D7BFF), shape: BoxShape.circle)),
              const Spacer(),
              if (cash > 0) Text('£${cash.toStringAsFixed(cash % 1 == 0 ? 0 : 2)}', style: const TextStyle(fontSize: 9, color: Color(0xFFB7791F), fontWeight: FontWeight.w700)),
            ]),
            Expanded(child: Text(line, style: const TextStyle(fontSize: 9, height: 1.15), overflow: TextOverflow.fade)),
          ])),
        ),
      ));
    }
    return Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(children: [
      Row(children: [
        IconButton(onPressed: () => onMove(-1), icon: const Icon(Icons.chevron_left)),
        Expanded(child: Text('${monthNames[m - 1]} $y', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
        IconButton(onPressed: () => onMove(1), icon: const Icon(Icons.chevron_right)),
      ]),
      Row(children: [for (final h in 'SMTWTFS'.split('')) Expanded(child: Center(child: Text(h, style: TextStyle(color: mutedColor(context), fontWeight: FontWeight.w700))))]),
      GridView.count(crossAxisCount: 7, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: .72, children: cells),
    ])));
  }
}

class _DayEditor extends StatelessWidget {
  final String date; final void Function(String) openWeek;
  const _DayEditor({super.key, required this.date, required this.openWeek});

  void _learn(Fix? fix, String v) {
    if (store.profile['learn'] != 'no' && fix != null && fix.exact && v.trim().isNotEmpty) store.learnPlace(fix.pos, v.trim());
  }

  @override
  Widget build(BuildContext context) {
    final e = store.dget(date), r = store.tachoDay(date);
    final tacho = store.card == null ? '🚚 Load your .ddd file in Timesheet to see the tacho for this day. You can still write the diary now.'
        : r == null ? '🚚 No tacho activity on this day.'
        : '🚚 Tacho: ${r.startTime}–${r.finishTime}'
            '${store.fixLabel(r.startFix).isNotEmpty || store.fixLabel(r.endFix).isNotEmpty ? ' · ${store.fixLabel(r.startFix).isEmpty ? '?' : store.fixLabel(r.startFix)} → ${store.fixLabel(r.endFix).isEmpty ? '?' : store.fixLabel(r.endFix)}' : ''}'
            ' · driving ${r.driving}${r.drops.isNotEmpty ? ' · GPS drops: ${store.fmtStops(store.gpsStops(r))}' : ''}'
            '${r.stops.isNotEmpty ? ' · stops with work: ${r.stops.map((x) => x.label).join(', ')}' : ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _NearCard(date: date),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tacho, style: TextStyle(color: mutedColor(context), fontSize: 13)),
        const SizedBox(height: 12),
        PlaceField(label: 'Start place', value: (e['start'] ?? '').toString(), hint: r != null && store.fixLabel(r.startFix).isNotEmpty ? store.fixLabel(r.startFix) : 'e.g. Scorrier',
            onChanged: (v) => store.setDiary(date, 'start', v), onDone: (v) => _learn(r?.startFix, v),
            onLocate: () async { final p = await locatePicker(context, '📍 Where did you start?'); if (p != null) store.setDiary(date, 'start', p.name); }),
        const SizedBox(height: 10),
        PlaceField(label: 'Finish place', value: (e['finish'] ?? '').toString(), hint: r != null && store.fixLabel(r.endFix).isNotEmpty ? store.fixLabel(r.endFix) : 'e.g. Kepak Merthyr',
            onChanged: (v) => store.setDiary(date, 'finish', v), onDone: (v) => _learn(r?.endFix, v),
            onLocate: () async { final p = await locatePicker(context, '📍 Where did you finish?'); if (p != null) store.setDiary(date, 'finish', p.name); }),
      ]))),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionTitle('Drops, pickups, coupling'),
        StopsEditor(date: date),
        const SizedBox(height: 8),
        _FrequentChips(date: date),
      ]))),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionTitle('Expenses'),
        DayExpenses(date: date),
      ]))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), child: Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(icon: const Icon(Icons.download, size: 18), label: const Text('Copy from tacho'), onPressed: () {
          if (r == null) { alert(context, 'The tacho has nothing for this day.'); return; }
          if (store.fixLabel(r.startFix).isNotEmpty) store.setDiary(date, 'start', store.fixLabel(r.startFix));
          if (store.fixLabel(r.endFix).isNotEmpty) store.setDiary(date, 'finish', store.fixLabel(r.endFix));
          if (r.drops.isNotEmpty && store.stopsOn(date).isEmpty) store.setStops(date, store.gpsStops(r));
        }),
        OutlinedButton.icon(icon: const Icon(Icons.description_outlined, size: 18), label: const Text('Open this week\'s timesheet'), onPressed: () => openWeek(sundayOfKey(date))),
        TextButton(onPressed: () async {
          if (store.diary[date] == null || !await confirm(context, 'Clear the places and drops for this day? Expenses are kept.', ok: 'Clear')) return;
          store.diary.remove(date); store.changed();
        }, child: const Text('Clear day')),
      ])),
    ]);
  }
}

// ---- stops: drops, pickups, coupling ---------------------------------------------------------
class StopsEditor extends StatelessWidget {
  final String date;
  const StopsEditor({super.key, required this.date});

  static const _icons = {'pickup': '⬆', 'couple': '🔗', 'uncouple': '✂', 'other': '•'};

  @override
  Widget build(BuildContext context) {
    final l = store.stopsOn(date), endT = store.trailerBefore(date, l.length);
    void save(List<J> x) => store.setStops(date, x);
    var drops = 0;
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (endT != null)
        Container(
          margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(color: const Color(0xFF7C3AED).withValues(alpha: .1), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(child: Text.rich(TextSpan(children: [
              const TextSpan(text: '🚛 Trailer '), TextSpan(text: endT.ref, style: const TextStyle(fontWeight: FontWeight.w800)),
              TextSpan(text: ' coupled${endT.date != date ? ' since ${dayNames[dayIdx(endT.date)].substring(0, 3)} ${fmtDay(endT.date)}' : ''}${endT.at.isNotEmpty ? ' at ${endT.at}' : ''}'),
            ]))),
            TextButton(onPressed: () => save([...l, {'type': 'uncouple', 'name': '', 'ref': endT.ref}]), child: Text('✂ Uncouple ${endT.ref}')),
          ]),
        ),
      if (l.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('Nothing added yet.', style: TextStyle(color: mutedColor(context)))),
      for (var n = 0; n < l.length; n++)
        Padding(
          key: ValueKey('$date-$n'),
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 8), child: CircleAvatar(
              radius: 14, backgroundColor: l[n]['type'] == 'drop' ? orange : cs.secondaryContainer,
              child: Text(l[n]['type'] == 'drop' ? '${++drops}' : _icons[l[n]['type']] ?? '•', style: TextStyle(color: l[n]['type'] == 'drop' ? Colors.white : cs.onSecondaryContainer, fontWeight: FontWeight.w800, fontSize: 13)),
            )),
            const SizedBox(width: 8),
            Expanded(child: Column(children: [
              Row(children: [
                DropdownButton<String>(
                  value: stopTypes.containsKey(l[n]['type']) ? l[n]['type'] : 'drop', underline: const SizedBox(), isDense: true,
                  items: [for (final t in stopTypes.entries) DropdownMenuItem(value: t.key, child: Text(t.value, style: const TextStyle(fontWeight: FontWeight.w700)))],
                  onChanged: (v) { final x = store.stopsOn(date); x[n]['type'] = v; save(x); },
                ),
                const Spacer(),
                IconButton(visualDensity: VisualDensity.compact, tooltip: hasLL(l[n]) ? 'Located. Tap to locate again' : 'Use my location',
                    icon: Icon(hasLL(l[n]) ? Icons.location_on : Icons.location_on_outlined, color: hasLL(l[n]) ? orange : null, size: 20),
                    onPressed: () async {
                      final p = await locatePicker(context, '📍 Where is this ${(stopTypes[l[n]['type']] ?? 'stop').toLowerCase()}?');
                      if (p == null) return;
                      final x = store.stopsOn(date); x[n]['name'] = p.name;
                      if (p.lat != null) { x[n]['lat'] = p.lat; x[n]['lon'] = p.lon; }
                      save(x);
                    }),
                IconButton(visualDensity: VisualDensity.compact, tooltip: 'Remove', icon: const Icon(Icons.close, size: 20), onPressed: () { final x = store.stopsOn(date)..removeAt(n); save(x); }),
              ]),
              PlaceField(
                value: (l[n]['name'] ?? '').toString(), hint: "Name, e.g. Sainsbury's Paignton",
                prev: () { final x = store.stopsOn(date); return n > 0 ? (x[n - 1]['name'] ?? '').toString() : (store.dget(date)['start'] ?? '').toString(); },
                onChanged: (v) { final x = store.stopsOn(date); if (n < x.length) { x[n]['name'] = v; save(x); } },
                onPick: (s) { if (s.lat == null) return; final x = store.stopsOn(date); x[n]['lat'] = s.lat; x[n]['lon'] = s.lon; save(x); },
              ),
              const SizedBox(height: 6),
              SyncedField(
                value: (l[n]['ref'] ?? '').toString(),
                hint: l[n]['type'] == 'couple' ? 'Trailer no.' : (store.trailerBefore(date, n) != null ? '🚛 ${store.trailerBefore(date, n)!.ref}' : 'Trailer / ref'),
                onChanged: (v) { final x = store.stopsOn(date); if (n < x.length) { x[n]['ref'] = v; save(x); } },
              ),
            ])),
          ]),
        ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final t in ['drop', 'pickup', 'couple', 'uncouple'])
          ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(stopTypes[t]!), onPressed: () {
            save([...l, {'type': t, 'name': '', if (t == 'uncouple' && endT != null) 'ref': endT.ref}]);
          }),
        ActionChip(avatar: const Icon(Icons.repeat, size: 16), label: const Text('Same as another day'), onPressed: () => _copyDay(context)),
      ]),
    ]);
  }

  // ↻ Same as another day: copy a regular run.
  Future<void> _copyDay(BuildContext context) async {
    bool has(String d) => ((store.diary[d]!['stops'] ?? const []) as List).any((x) => '${x['name'] ?? ''}${x['ref'] ?? ''}'.trim().isNotEmpty);
    final days = (store.diary.keys.where((d) => d != date && has(d)).toList()..sort()).reversed.take(14).toList();
    if (days.isEmpty) { toast(context, 'No other days with drops yet'); return; }
    final pick = await sheet<String>(context, (c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('↻ Same as another day', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Text("Copies that day's drops, pickups and coupling to ${dayNames[dayIdx(date)]} ${fmtDay(date)}. You can change them after.", style: TextStyle(color: mutedColor(c))),
          const SizedBox(height: 8),
          for (final d in days)
            ListTile(contentPadding: EdgeInsets.zero, title: Text('${dayNames[dayIdx(d)].substring(0, 3)} ${fmtDay(d)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(store.fmtStops(store.diary[d]!['stops'] as List?), maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () => Navigator.pop(c, d)),
        ]));
    if (pick == null) return;
    final src = store.stopsOn(pick).where((x) => '${x['name'] ?? ''}${x['ref'] ?? ''}'.trim().isNotEmpty).toList();
    final cur = store.stopsOn(date).where((x) => '${x['name'] ?? ''}${x['ref'] ?? ''}'.trim().isNotEmpty).toList();
    store.setStops(date, [...cur, ...src]);
    if (context.mounted) toast(context, 'Copied ${src.length} from ${fmtDay(pick)}');
  }
}

// Stops you've used before, most used first, for one-tap entry. Hold one to rename, hide or star it.
class _FrequentChips extends StatefulWidget {
  final String date;
  const _FrequentChips({required this.date});
  @override
  State<_FrequentChips> createState() => _FrequentChipsState();
}

class _FrequentChipsState extends State<_FrequentChips> {
  bool all = false;
  @override
  Widget build(BuildContext context) {
    final freq = store.frequentStops();
    if (freq.isEmpty) return Text('Names you add show up here for next time.', style: TextStyle(color: mutedColor(context), fontSize: 13));
    final shown = all ? freq : freq.take(8).toList();
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final s in shown)
        GestureDetector(
          onLongPress: () { HapticFeedback.mediumImpact(); _menu(context, s); },
          child: ActionChip(
            label: Text('${s.type == 'drop' ? '' : '${stopTypes[s.type]} · '}${s.name}'),
            onPressed: () => store.addStopTo(widget.date, {'type': s.type, 'name': s.name, if (s.lat != null) 'lat': s.lat, if (s.lon != null) 'lon': s.lon}),
          ),
        ),
      if (freq.length > 8) ActionChip(label: Text(all ? 'Less ▴' : '+${freq.length - 8} more ▾'), onPressed: () => setState(() => all = !all)),
    ]);
  }

  Future<void> _menu(BuildContext context, ({String type, String name, int c, double? lat, double? lon}) s) async {
    var type = s.type;
    final name = TextEditingController(text: s.name);
    await sheet(context, (c) => StatefulBuilder(builder: (c, set) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.name, style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(initialValue: type, decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final t in stopTypes.entries) DropdownMenuItem(value: t.key, child: Text(t.value))], onChanged: (v) => set(() => type = v ?? type)),
          const SizedBox(height: 10),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 6),
          Text('"Save everywhere" changes it in every day of your diary that uses it.', style: TextStyle(color: mutedColor(c), fontSize: 13)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            OutlinedButton(onPressed: () { store.hideStop(s.type, s.name); Navigator.pop(c); toast(context, 'Removed from the list (your diary is unchanged)'); }, child: const Text('Remove from list')),
            OutlinedButton(onPressed: () { Navigator.pop(c); starEditor(context, {'name': s.name, if (s.lat != null) 'lat': s.lat, if (s.lon != null) 'lon': s.lon}); }, child: const Text('⭐ Star it')),
            FilledButton(onPressed: () {
              if (name.text.trim().isEmpty) return;
              store.renameStopEverywhere(s.type, s.name, type, name.text.trim());
              Navigator.pop(c);
            }, child: const Text('Save everywhere')),
          ]),
        ])));
  }
}

// ---- 📍 "Were you here?" ------------------------------------------------------------------------
class _NearCard extends StatelessWidget {
  final String date;
  const _NearCard({required this.date});
  @override
  Widget build(BuildContext context) {
    final list = store.nearbyFor(date);
    if (list.isEmpty) return const SizedBox();
    return Card(
      color: orange.withValues(alpha: .08),
      child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 8, 6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('📍 Were you here?', style: TextStyle(fontWeight: FontWeight.w800)),
        for (final v in list)
          Row(children: [
            Expanded(child: ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${v.src == 'phone' ? '📱 your phone' : '🚚 tacho GPS'} · ${v.time}'))),
            TextButton(onPressed: () { store.addStopTo(date, {'type': 'drop', 'name': v.name, 'lat': v.lat, 'lon': v.lon}); toast(context, 'Added Drop ${v.name}'); }, child: const Text('+ Drop')),
            TextButton(onPressed: () { store.addStopTo(date, {'type': 'pickup', 'name': v.name, 'lat': v.lat, 'lon': v.lon}); toast(context, 'Added Pickup ${v.name}'); }, child: const Text('+ Pickup')),
            IconButton(tooltip: "No, I wasn't", icon: const Icon(Icons.close, size: 18), onPressed: () => store.dismiss(date, v.name)),
          ]),
      ])),
    );
  }
}

// ---- expenses for one day ----------------------------------------------------------------------------
class DayExpenses extends StatelessWidget {
  final String date;
  const DayExpenses({super.key, required this.date});
  @override
  Widget build(BuildContext context) {
    final rows = store.expensesOn(date), sun = sundayOfKey(date);
    final tot = rows.fold(0.0, (a, e) => a + money(e['amount']));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (rows.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('No expenses on this day.', style: TextStyle(color: mutedColor(context)))),
      for (final e in rows) ExpenseRow(key: ValueKey(e['id']), e: e, sun: sun),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final t in expenseTypes.entries) ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(t.value), onPressed: () => store.addExpense(date, t.key)),
      ]),
      if (tot > 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Total this day: £${tot.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800))),
    ]);
  }
}

class ExpenseRow extends StatelessWidget {
  final J e; final String sun; final bool showDay;
  const ExpenseRow({super.key, required this.e, required this.sun, this.showDay = false});
  @override
  Widget build(BuildContext context) {
    void set(String k, String v) { e[k] = v; store.weekState(sun)['editedAt'] = DateTime.now().millisecondsSinceEpoch; store.changed(); }
    return Container(
      margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Row(children: [
          if (showDay) ...[
            DropdownButton<int>(value: (e['day'] as num).toInt(), underline: const SizedBox(), isDense: true,
                items: [for (var i = 0; i < 7; i++) DropdownMenuItem(value: i, child: Text('${dayNames[i].substring(0, 3)} ${fmtDay(addDays(sun, i))}'))],
                onChanged: (v) { e['day'] = v; store.changed(); }),
            const SizedBox(width: 8),
          ],
          DropdownButton<String>(value: expenseTypes.containsKey(e['type']) ? e['type'] : 'market', underline: const SizedBox(), isDense: true,
              items: [for (final t in expenseTypes.entries) DropdownMenuItem(value: t.key, child: Text(t.value, style: const TextStyle(fontWeight: FontWeight.w700)))],
              onChanged: (v) => set('type', v!)),
          const Spacer(),
          if (e['att'] != null) ...[
            AttThumb(e['att'] as Map),
            IconButton(tooltip: 'Remove photo', icon: const Icon(Icons.close, size: 18), onPressed: () => store.removeAttachment(e)),
          ] else ...[
            IconButton.filledTonal(tooltip: 'Scan receipt', icon: const Icon(Icons.document_scanner_outlined, size: 20), onPressed: () async {
              final said = await scanInto(context, e);
              if (said != null && context.mounted) toast(context, 'Receipt saved${said.isNotEmpty ? ' · $said' : ''}');
            }),
            IconButton(tooltip: 'Attach photo or PDF', icon: const Icon(Icons.attach_file, size: 20), onPressed: () async {
              final said = await attachInto(context, e);
              if (said != null && context.mounted) toast(context, 'Receipt added${said.isNotEmpty ? ' · $said' : ''}');
            }),
          ],
          IconButton(tooltip: 'Delete this expense', icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => store.removeExpense(sun, e)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(flex: 3, child: SyncedField(value: (e['note'] ?? '').toString(), hint: 'Note, e.g. Gordano', onChanged: (v) => set('note', v))),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: SyncedField(value: (e['amount'] ?? '').toString(), hint: '£ amount', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => set('amount', v))),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: SyncedField(value: (e['vat'] ?? '').toString(), hint: 'VAT', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => set('vat', v))),
        ]),
      ]),
    );
  }
}
