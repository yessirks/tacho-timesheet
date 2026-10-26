// Timesheet: .ddd → tacho values + your diary + your edits → the filled PDF (preview, save, share).
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import '../core/tacho.dart' show Fix;
import '../core/week.dart';
import '../data/pdf_service.dart';
import '../data/store.dart';
import 'common.dart';
import 'diary_tab.dart' show StopsEditor, ExpenseRow;
import 'receipts.dart';

class SheetTab extends StatefulWidget {
  final ValueNotifier<String> week;
  const SheetTab({super.key, required this.week});
  @override
  State<SheetTab> createState() => _SheetTabState();
}

class _SheetTabState extends State<SheetTab> {
  String get sun => widget.week.value;
  bool working = false;

  Future<void> loadCard() async {
    final f = await pickOne();
    if (f == null) return;
    try {
      await store.loadCard(f.bytes, f.name);
      final keys = store.weekKeys();
      final latest = store.prep!.shifts.isEmpty ? keys.first : sundayOf(store.prep!.shifts.last.cardIn);
      widget.week.value = latest;
      if (mounted) toast(context, 'Card loaded: ${store.card!.identification.firstNames} ${store.card!.identification.surname}');
    } on FormatException catch (e) {
      if (mounted) alert(context, 'Could not read this file: ${e.message}');
    }
  }

  Future<void> _withPdf(Future<void> Function(Uint8List bytes) fn) async {
    setState(() => working = true);
    try { await fn(await buildWeekPdf(store, sun)); } catch (e) { if (mounted) alert(context, 'PDF error: $e'); }
    if (mounted) setState(() => working = false);
  }

  String _subject() => AppStore.fillTpl((store.profile['emailSubjTpl'] as String?) ?? AppStore.defaultSubject, _vals()).trim();
  String _body() => AppStore.fillTpl((store.profile['emailTpl'] as String?) ?? AppStore.defaultEmail, _vals());
  Map<String, String> _vals() { final t = weekTotals(store, sun); return store.emailVals(sun, nights: t.uk + t.eu, expenses: t.total); }

  Future<void> save() => _withPdf((b) async {
        final uri = await FilePicker.saveFile(fileName: store.fileName(sun), bytes: b, mimeType: 'application/pdf');
        if (uri == null) return;
        store.markDone(sun, 'downloaded');
        if (mounted) toast(context, '✓ Saved ${store.fileName(sun)}');
      });

  Future<void> share() => _withPdf((b) async {
        final f = await tempFile(store.fileName(sun), b);
        final r = await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/pdf')], subject: _subject(), text: _body()));
        if (r.status != ShareResultStatus.dismissed) { store.markDone(sun, 'shared'); if (mounted) toast(context, '✓ Shared ${store.fileName(sun)}'); }
      });

  void preview() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
        appBar: AppBar(title: Text(store.fileName(sun))),
        body: PdfPreview(build: (_) => buildWeekPdf(store, sun), canChangeOrientation: false, canChangePageFormat: false, canDebug: false,
            pdfFileName: store.fileName(sun), allowPrinting: true, allowSharing: true),
      )));

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([store, widget.week]), builder: (context, _) {
        final keys = store.weekKeys();
        if (!keys.contains(sun)) keys.insert(0, sun);
        final w = store.tachoWeek(sun), id = store.card?.identification;
        final n = w?.rows.where((r) => r.worked).length ?? 0;
        final done = store.weekState(sun)['done'] as Map?;
        final edited = store.weekState(sun)['editedAt'] as num?;
        final changedSince = done != null && edited != null && edited > (done['at'] as num);
        return Scaffold(
          appBar: AppBar(title: const Text('Timesheet', style: TextStyle(fontWeight: FontWeight.w800)), actions: [
            IconButton(tooltip: 'Load tacho card file (.ddd)', icon: const Icon(Icons.sd_card_outlined), onPressed: loadCard),
          ]),
          body: ListView(padding: const EdgeInsets.only(bottom: 110), children: [
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (id == null)
                FilledButton.icon(onPressed: loadCard, icon: const Icon(Icons.sd_card), label: const Text('Load your tacho card file (.ddd)'))
              else
                Row(children: [
                  const Icon(Icons.person, size: 18), const SizedBox(width: 6),
                  Expanded(child: Text('${id.firstNames} ${id.surname}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  if (store.card!.days.isNotEmpty) Text('tacho to ${fmtDay(localKey(store.card!.days.last.date))}', style: TextStyle(color: mutedColor(context))),
                ]),
              const SizedBox(height: 10),
              Row(children: [
                IconButton(onPressed: keys.indexOf(sun) < keys.length - 1 ? () => widget.week.value = keys[keys.indexOf(sun) + 1] : null, icon: const Icon(Icons.chevron_left)),
                Expanded(child: DropdownButtonFormField<String>(
                  initialValue: sun, isExpanded: true, key: ValueKey(sun),
                  items: [for (final k in keys) DropdownMenuItem(value: k, child: Text('w/c Sun ${fmtDay(k)} ${k.substring(0, 4)}${store.shiftsIn(k) > 0 ? ' · ${store.shiftsIn(k)} shifts' : ''}${store.weeks[k]?['done'] != null ? ' · ✓ sent' : ''}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => widget.week.value = v!,
                )),
                IconButton(onPressed: keys.indexOf(sun) > 0 ? () => widget.week.value = keys[keys.indexOf(sun) - 1] : null, icon: const Icon(Icons.chevron_right)),
              ]),
              Text('${fmtShort(sun)} – ${fmtShort(addDays(sun, 6))}${store.card != null ? ' · $n day${n == 1 ? '' : 's'} on the tacho' : ' · no card loaded: fill in by hand'}',
                  style: TextStyle(color: mutedColor(context), fontSize: 13)),
              if (store.status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(store.status, style: TextStyle(color: mutedColor(context), fontSize: 12))),
              const SizedBox(height: 6),
              Text(done == null ? 'Not sent yet' : '${changedSince ? '⚠' : '✓'} ${done['how'] == 'shared' ? 'Shared' : 'Saved'} ${_when(done['at'] as num)}${changedSince ? ' · changed since, send it again' : ''}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: done == null ? mutedColor(context) : changedSince ? const Color(0xFFB7791F) : const Color(0xFF1D7A46))),
            ]))),
            for (var i = 0; i < 7; i++) _DayCard(key: ValueKey('$sun-$i'), sun: sun, i: i),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: _Footer(sun: sun))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Expenses this week'),
              for (final e in store.weekState(sun)['expenses'] as List) ExpenseRow(key: ValueKey(e['id']), e: e as J, sun: sun, showDay: true),
              Align(alignment: Alignment.centerLeft, child: ActionChip(avatar: const Icon(Icons.add, size: 16), label: const Text('Add expense'), onPressed: () {
                final night = List.generate(7, (i) => i).where((i) => store.dayVal(sun, i, 'nightOut').isNotEmpty).firstOrNull ?? 0;
                store.addExpense(addDays(sun, night), 'parking');
              })),
              const SizedBox(height: 14),
              const SectionTitle('Other pages to attach'),
              for (final a in (store.weekState(sun)['other'] as List).cast<J>())
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
                  AttThumb(a),
                  const SizedBox(width: 8),
                  Expanded(child: SyncedField(value: (a['caption'] ?? '').toString(), hint: 'Caption (optional)', onChanged: (v) { a['caption'] = v; store.changed(); })),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => store.removeOther(sun, a)),
                ])),
              Align(alignment: Alignment.centerLeft, child: ActionChip(avatar: const Icon(Icons.attach_file, size: 16), label: const Text('Attach a page (photo or PDF)'), onPressed: () async {
                final holder = <String, dynamic>{};
                if (await attachInto(context, holder, read: false) == null) return;
                (store.weekState(sun)['other'] as List).add({...holder['att'] as J, 'caption': ''});
                store.changed();
              })),
            ]))),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Email'),
              _CopyRow(label: 'Subject', text: _subject()),
              const SizedBox(height: 8),
              _CopyRow(label: 'Message', text: _body(), lines: 7),
              Text('Edit the wording in Me › Email.', style: TextStyle(color: mutedColor(context), fontSize: 12)),
            ]))),
          ]),
          bottomNavigationBar: SafeArea(child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, boxShadow: const [BoxShadow(blurRadius: 12, color: Color(0x22000000))]),
            child: Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: preview, icon: const Icon(Icons.visibility_outlined), label: const Text('Preview'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: working ? null : save, icon: const Icon(Icons.save_alt), label: const Text('Save'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(onPressed: working ? null : share, icon: working ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send), label: const Text('Send'))),
            ]),
          )),
        );
      });

  String _when(num ms) {
    final t = local(ms.toInt()), d = localKey(ms.toInt());
    return '${dayNames[dayIdx(d)].substring(0, 3)} ${fmtDay(d)} ${t.time}';
  }
}

class _CopyRow extends StatelessWidget {
  final String label, text; final int lines;
  const _CopyRow({required this.label, required this.text, this.lines = 1});
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: InputDecorator(decoration: InputDecoration(labelText: label), child: Text(text, maxLines: lines, overflow: TextOverflow.ellipsis))),
        IconButton(tooltip: 'Copy', icon: const Icon(Icons.copy, size: 20), onPressed: () { Clipboard.setData(ClipboardData(text: text)); toast(context, 'Copied'); }),
      ]);
}

class _DayCard extends StatelessWidget {
  final String sun; final int i;
  const _DayCard({super.key, required this.sun, required this.i});
  @override
  Widget build(BuildContext context) {
    final r = store.tachoWeek(sun)?.rows[i], date = addDays(sun, i);
    final has = r != null && r.worked;
    String v(String k) => store.dayVal(sun, i, k);
    void set(String k, String x) => store.setDayVal(sun, i, k, x);
    final tags = <String>[
      if (r != null && r.shifts.length > 1) '${r.shifts.length} shifts merged',
      if (r != null && r.finishNote != null) 'finishes ${r.finishNote}',
      if (has) 'other work ${hm(r.workMin)} · driving ${r.driving}' else 'no tacho activity',
    ];
    String hintFor(Fix? fix) => fix == null ? '' : fix.exact ? coordText(fix.pos) : 'roughly near ${store.label(fix.pos).isNotEmpty ? store.label(fix.pos) : coordText(fix.pos)}';
    void learn(Fix? fix, String val) { if (store.profile['learn'] != 'no' && fix != null && fix.exact && val.trim().isNotEmpty) store.learnPlace(fix.pos, val.trim()); }
    final places = v('startPlace').isEmpty && v('finishPlace').isEmpty ? '' : '${v('startPlace').isEmpty ? '?' : v('startPlace')} → ${v('finishPlace').isEmpty ? '?' : v('finishPlace')}';
    final summary = v('startTime').isNotEmpty ? '${v('startTime')}–${v('finishTime')}  $places' : places.isNotEmpty ? places : 'Not worked';
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false, shape: const RoundedRectangleBorder(), collapsedShape: const RoundedRectangleBorder(),
          leading: CircleAvatar(backgroundColor: has ? orange : Theme.of(context).colorScheme.surfaceContainerLowest,
              child: Text(dayNames[i].substring(0, 2), style: TextStyle(color: has ? Colors.white : mutedColor(context), fontWeight: FontWeight.w800, fontSize: 13))),
          title: Text('${dayNames[i]} ${fmtDay(date)}', style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: v('nightOut').isNotEmpty ? Chip(label: Text('🌙 ${v('nightOut')}'), visualDensity: VisualDensity.compact) : null,
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          children: [
            Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, children: [for (final t in tags) Chip(label: Text(t, style: const TextStyle(fontSize: 12)), visualDensity: VisualDensity.compact)])),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: SyncedField(label: 'Start time', hint: 'hh:mm', value: v('startTime'), keyboard: TextInputType.datetime, onChanged: (x) => set('startTime', x))),
              const SizedBox(width: 8),
              Expanded(child: SyncedField(label: 'Finish time', hint: 'hh:mm', value: v('finishTime'), keyboard: TextInputType.datetime, onChanged: (x) => set('finishTime', x))),
            ]),
            const SizedBox(height: 10),
            PlaceField(label: 'Start place', value: v('startPlace'), hint: hintFor(r?.startFix), onChanged: (x) => set('startPlace', x), onDone: (x) => learn(r?.startFix, x)),
            const SizedBox(height: 10),
            PlaceField(label: 'Finish place', value: v('finishPlace'), hint: hintFor(r?.endFix), onChanged: (x) => set('finishPlace', x), onDone: (x) => learn(r?.endFix, x)),
            const SizedBox(height: 12),
            const SectionTitle('Drops, pickups, coupling'),
            StopsEditor(date: date),
            if (r != null && r.drops.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final d in r.drops)
                  ActionChip(avatar: const Icon(Icons.gps_fixed, size: 14), label: Text('${local(d.time).time} ${d.opName} · ${store.label(d.pos).isNotEmpty ? store.label(d.pos) : coordText(d.pos)}'),
                      onPressed: () => store.addStopTo(date, {'type': d.op == 1 ? 'pickup' : 'drop', 'name': store.label(d.pos).isNotEmpty ? store.label(d.pos) : coordText(d.pos)})),
              ]),
            ],
            if (r != null && r.stops.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Stops with work: ${r.stops.map((x) => '${x.label} (${x.work}m)').join(', ')}',
                style: TextStyle(color: mutedColor(context), fontSize: 12))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: ['', 'UK', 'EU'].contains(v('nightOut')) ? v('nightOut') : '', decoration: const InputDecoration(labelText: 'Night out'),
                items: const [DropdownMenuItem(value: '', child: Text('No')), DropdownMenuItem(value: 'UK', child: Text('UK')), DropdownMenuItem(value: 'EU', child: Text('EU'))],
                onChanged: (x) => set('nightOut', x ?? ''),
              )),
              const SizedBox(width: 8),
              Expanded(child: SyncedField(label: 'Driving hrs', value: v('driving'), onChanged: (x) => set('driving', x))),
            ]),
            const SizedBox(height: 10),
            SyncedField(label: 'Stayed at (page 2 "Place")', value: v('stayed'), onChanged: (x) => set('stayed', x)),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => store.resetDay(sun, i), icon: const Icon(Icons.restart_alt, size: 18), label: const Text('Put the tacho values back'))),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final String sun;
  const _Footer({required this.sun});
  @override
  Widget build(BuildContext context) {
    String v(String k) => store.footVal(sun, k);
    void set(String k, String x) => store.setFootVal(sun, k, x);
    Widget yesNo(String k, String label) => DropdownButtonFormField<String>(
          initialValue: ['', 'YES', 'NO'].contains(v(k)) ? v(k) : '', decoration: InputDecoration(labelText: label),
          items: const [DropdownMenuItem(value: '', child: Text('—')), DropdownMenuItem(value: 'YES', child: Text('YES')), DropdownMenuItem(value: 'NO', child: Text('NO'))],
          onChanged: (x) => set(k, x ?? ''),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Totals and details'),
      Row(children: [
        Expanded(child: SyncedField(label: 'Weekdays', value: v('totalWeekdays'), keyboard: TextInputType.number, onChanged: (x) => set('totalWeekdays', x))),
        const SizedBox(width: 8),
        Expanded(child: SyncedField(label: 'Weekend days', value: v('totalWeekendDays'), keyboard: TextInputType.number, onChanged: (x) => set('totalWeekendDays', x))),
      ]),
      const SizedBox(height: 10),
      Row(children: [Expanded(child: yesNo('away24', '24hr away from home')), const SizedBox(width: 8), Expanded(child: yesNo('declaration', 'Declaration'))]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: SyncedField(label: 'Week commencing', value: v('weekCommencing'), onChanged: (x) => set('weekCommencing', x))),
        const SizedBox(width: 8),
        Expanded(child: SyncedField(label: 'Vehicle', value: v('vehicle'), onChanged: (x) => set('vehicle', x))),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: SyncedField(label: 'Signed date', value: v('signedDate'), onChanged: (x) => set('signedDate', x))),
        const SizedBox(width: 8),
        Expanded(child: SyncedField(label: 'W/E date', value: v('weDate'), onChanged: (x) => set('weDate', x))),
      ]),
    ]);
  }
}
