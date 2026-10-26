// Gathers a week's values, expenses and receipts and builds the timesheet PDF (buildData in app.js).
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import '../core/timesheet_pdf.dart';
import '../core/week.dart';
import 'store.dart';

Uint8List? _logo;

class WeekTotals { final int uk, eu; final double total; WeekTotals(this.uk, this.eu, this.total); }

/// Page 2 rows and totals for a week (the form has no food column: food goes under "market").
(List<P2Row>, P2Totals) expenseRows(AppStore s, String sun) {
  final ws = s.weekState(sun);
  final rows = List.generate(7, (i) => <String, dynamic>{
        'parking': 0.0, 'tolls': 0.0, 'market': 0.0, 'vat': 0.0, 'notes': {'parking': <String>[], 'tolls': <String>[], 'market': <String>[]},
      });
  for (final e in ws['expenses'] as List) {
    if (money(e['amount']) == 0 && (e['note'] ?? '').toString().isEmpty) continue;
    final i = (e['day'] as num).toInt();
    if (i < 0 || i > 6) continue;
    final r = rows[i], col = e['type'] == 'food' ? 'market' : (e['type'] ?? 'market') as String;
    r[col] = (r[col] as double) + money(e['amount']);
    r['vat'] = (r['vat'] as double) + money(e['vat']);
    final note = e['type'] == 'food' ? 'Food ${e['note'] ?? ''}'.trim() : (e['note'] ?? '').toString();
    if (note.isNotEmpty) (r['notes'][col] as List<String>).add(note);
  }
  double? blank(double v) => v == 0 ? null : v;
  final out = <P2Row>[];
  var uk = 0, eu = 0;
  for (var i = 0; i < 7; i++) {
    final r = rows[i], night = s.dayVal(sun, i, 'nightOut');
    if (night == 'UK') uk++;
    if (night == 'EU') eu++;
    final p = r['parking'] as double, t = r['tolls'] as double, m = r['market'] as double;
    out.add(P2Row(place: s.dayVal(sun, i, 'stayed'), uk: night == 'UK', eu: night == 'EU',
        parking: blank(p), parkingNote: (r['notes']['parking'] as List).join('/'),
        tolls: blank(t), tollsNote: (r['notes']['tolls'] as List).join('/'),
        market: blank(m), marketNote: (r['notes']['market'] as List).join('/'),
        vat: blank(r['vat'] as double), total: blank(p + t + m)));
  }
  double sum(String k) => rows.fold(0.0, (a, r) => a + (r[k] as double));
  return (out, P2Totals(uk: uk, eu: eu, parking: blank(sum('parking')), tolls: blank(sum('tolls')), market: blank(sum('market')),
      vat: blank(sum('vat')), total: blank(sum('parking') + sum('tolls') + sum('market'))));
}

WeekTotals weekTotals(AppStore s, String sun) { final (_, t) = expenseRows(s, sun); return WeekTotals(t.uk, t.eu, t.total ?? 0); }

Future<List<Attachment>> _attachments(AppStore s, String sun) async {
  final ws = s.weekState(sun), out = <Attachment>[];
  Future<void> add(Map att, String caption) async {
    final f = s.attFile(att);
    if (f == null || !await f.exists()) return;
    final bytes = await f.readAsBytes();
    if (att['kind'] == 'pdf') {
      var n = 0;
      await for (final page in Printing.raster(bytes, dpi: 130)) {
        out.add(Attachment(await page.toPng(), n++ == 0 ? caption : ''));
      }
    } else {
      out.add(Attachment(bytes, caption));
    }
  }
  final exps = [for (final e in ws['expenses'] as List) if (e['att'] != null) e]..sort((a, b) => (a['day'] as num).compareTo(b['day'] as num));
  for (final e in exps) {
    final i = (e['day'] as num).toInt(), amt = money(e['amount']);
    await add(e['att'] as Map, '${dayNames[i]} ${fmtShort(addDays(sun, i))} - ${expenseTypes[e['type']] ?? ''}'
        '${(e['note'] ?? '').toString().isNotEmpty ? ' (${e['note']})' : ''}${amt != 0 ? ' - £${amt.toStringAsFixed(2)}' : ''}');
  }
  for (final a in ws['other'] as List) { await add(a as Map, (a['caption'] ?? '').toString()); }
  return out;
}

Future<Uint8List> buildWeekPdf(AppStore s, String sun, {bool withAttachments = true}) async {
  _logo ??= (await rootBundle.load('assets/cbt_logo.png')).buffer.asUint8List();
  String f(String k) => s.footVal(sun, k);
  final sig = s.signatureBytes;
  final (rows, totals) = expenseRows(s, sun);
  return buildTimesheet(
    logo: _logo,
    page2: f('page2') != 'no',
    p1: P1Data(
      name: f('name'), weekCommencing: f('weekCommencing'), totalWeekdays: f('totalWeekdays'), totalWeekendDays: f('totalWeekendDays'),
      away24: f('away24'), declaration: f('declaration'), signature: sig,
      days: [
        for (var i = 0; i < 7; i++)
          P1Day(startTime: s.dayVal(sun, i, 'startTime'), finishTime: s.dayVal(sun, i, 'finishTime'), startPlace: s.dayVal(sun, i, 'startPlace'),
              finishPlace: s.dayVal(sun, i, 'finishPlace'), drops: s.dayVal(sun, i, 'drops'), nightOut: s.dayVal(sun, i, 'nightOut'), driving: s.dayVal(sun, i, 'driving')),
      ],
    ),
    p2: P2Data(nameLine: f('nameLine'), addr1: f('addr1'), addr2: f('addr2'), ni: f('ni'), vehicle: f('vehicle'), signedDate: f('signedDate'),
        weDate: f('weDate'), signature: sig, rows: rows, totals: totals),
    attachments: withAttachments ? await _attachments(s, sun) : const [],
  );
}

Future<Uint8List> buildBlankPdf() async {
  _logo ??= (await rootBundle.load('assets/cbt_logo.png')).buffer.asUint8List();
  return buildTimesheet(logo: _logo);
}
