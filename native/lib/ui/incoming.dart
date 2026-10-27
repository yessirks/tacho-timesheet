// What to do with a file or link another app shared with Tuki ("Open with" / "Share").
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../core/geo.dart' as geo;
import '../core/tacho.dart' show parseCard;
import '../core/week.dart';
import '../data/store.dart';
import 'common.dart';
import 'map_tab.dart' show starEditor;
import 'receipts.dart' show autoReadInto;

Future<void> handleIncoming(BuildContext context, Map item, {required void Function(String sunday) openWeek, required void Function(String date) openDay, required VoidCallback openMap}) async {
  if (item['error'] != null) { alert(context, 'Could not open that: ${item['error']}'); return; }
  final text = item['text'] as String?;
  if (text != null) {
    toast(context, 'Reading the link…');
    final c = await geo.coordsFromShare(text);
    if (!context.mounted) return;
    if (c == null) {
      alert(context, "That link doesn't have the exact spot in it. In Google Maps, press and hold the spot (a red pin appears), then Share that pin to Tuki.");
      return;
    }
    openMap();
    await starEditor(context, {'name': c.name, 'lat': c.lat, 'lon': c.lon});
    return;
  }
  final bytes = item['bytes'] as Uint8List?;
  if (bytes == null || bytes.isEmpty) return;
  final name = (item['name'] ?? 'file').toString(), lower = name.toLowerCase(), mime = (item['mime'] ?? '').toString();

  // A tacho card file?
  try {
    parseCard(bytes);
    await store.loadCard(bytes, name);
    final p = store.prep!;
    openWeek(p.shifts.isEmpty ? sundayOf(DateTime.now().millisecondsSinceEpoch) : sundayOf(p.shifts.last.cardIn));
    if (context.mounted) toast(context, 'Card loaded: ${store.card!.identification.firstNames} ${store.card!.identification.surname}');
    return;
  } catch (_) { /* not a card */ }
  if (!context.mounted) return;

  // A full Tuki backup (.zip)?
  if (bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B && lower.endsWith('.zip')) {
    if (!await confirm(context, 'Restore this Tuki backup? It is added to what is already here; nothing is deleted.', ok: 'Restore')) return;
    try { await store.importFull(bytes); if (context.mounted) toast(context, '✓ Restored'); } catch (e) { if (context.mounted) alert(context, 'That backup could not be read: $e'); }
    return;
  }

  final isPdf = mime == 'application/pdf' || lower.endsWith('.pdf');
  final isImage = mime.startsWith('image/') || RegExp(r'\.(jpe?g|png|webp|heic)$').hasMatch(lower);
  if (!isPdf && !isImage) {
    final s = utf8.decode(bytes, allowMalformed: true);
    // A Tuki backup (from this app or the web app)?
    if (s.trimLeft().startsWith('{') && RegExp(r'"(diary|stars|places|weeks|profile)"').hasMatch(s)) {
      if (!await confirm(context, 'Import this Tuki backup? It is added to what is already here; nothing is deleted.', ok: 'Import')) return;
      try { store.importAll(s); if (context.mounted) toast(context, '✓ Imported'); } catch (e) { if (context.mounted) alert(context, 'That file could not be read: $e'); }
      return;
    }
    // Places (GPX / KML / CSV)?
    final list = geo.parseImport(s);
    if (list.isNotEmpty) {
      for (final p in list) { store.addStar({'name': p.name, 'lat': p.lat, 'lon': p.lon, 'note': p.note}, save: false); }
      store.changed();
      openMap();
      if (context.mounted) toast(context, '⭐ Imported ${list.length} place${list.length > 1 ? 's' : ''}');
      return;
    }
    if (context.mounted) alert(context, "Tuki doesn't know what to do with $name.");
    return;
  }

  // A receipt: add it to an expense on a day you pick (today by default).
  final r = await _receiptDay(context, name);
  if (r == null || !context.mounted) return;
  var data = bytes;
  if (isImage) {
    final im = img.decodeImage(bytes);
    if (im == null) { alert(context, 'Could not open that photo.'); return; }
    final o = img.bakeOrientation(im), k = 1800 / (o.width > o.height ? o.width : o.height);
    data = img.encodeJpg(k < 1 ? img.copyResize(o, width: (o.width * k).round()) : o, quality: 85);
  }
  final e = store.addExpense(r.date, r.type);
  e['att'] = await store.saveAttachment(data, name, isPdf ? 'application/pdf' : 'image/jpeg');
  store.changed();
  openDay(r.date);
  final said = isImage ? await autoReadInto(e) : '';
  if (context.mounted) toast(context, 'Receipt added to ${fmtDay(r.date)}${said.isNotEmpty ? ' · $said' : ''}');
}

Future<({String date, String type})?> _receiptDay(BuildContext context, String name) {
  var date = todayKey(), type = 'parking';
  return sheet<({String date, String type})>(context, (c) => StatefulBuilder(builder: (c, set) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Add receipt', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        Text(name, style: TextStyle(color: mutedColor(c))),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < 7; i++)
            () {
              final d = addDays(todayKey(), -i);
              return ChoiceChip(label: Text(i == 0 ? 'Today' : i == 1 ? 'Yesterday' : '${dayNames[dayIdx(d)].substring(0, 3)} ${fmtDay(d)}'), selected: date == d, onSelected: (_) => set(() => date = d));
            }(),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 6, children: [for (final t in expenseTypes.entries) ChoiceChip(label: Text(t.value), selected: type == t.key, onSelected: (_) => set(() => type = t.key))]),
        const SizedBox(height: 14),
        Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(c, (date: date, type: type)), child: const Text('Add'))),
      ])));
}
