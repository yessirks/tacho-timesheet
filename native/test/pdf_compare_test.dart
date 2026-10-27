// Builds the sample week (scratchpad sample_week.json) with the Dart form so it can be compared pixel by
// pixel with form.js. Skipped unless TUKI_SAMPLE, TUKI_SIG and TUKI_PDF are set.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuki/core/timesheet_pdf.dart';

void main() {
  final env = Platform.environment;
  test('pdf matches the web app', () async {
    final s = jsonDecode(File(env['TUKI_SAMPLE']!).readAsStringSync()) as Map<String, dynamic>;
    final sig = File(env['TUKI_SIG']!).readAsBytesSync();
    double? n(dynamic v) => v is num ? v.toDouble() : null;
    final p1 = s['p1'] as Map<String, dynamic>, p2 = s['p2'] as Map<String, dynamic>;
    final bytes = await buildTimesheet(
      logo: File('assets/cbt_logo.png').readAsBytesSync(),
      p1: P1Data(
        name: p1['name'], weekCommencing: p1['weekCommencing'], totalWeekdays: p1['totalWeekdays'], totalWeekendDays: p1['totalWeekendDays'],
        away24: p1['away24'], declaration: p1['declaration'], signature: sig,
        days: [for (final d in p1['days']) P1Day(startTime: d['startTime'], finishTime: d['finishTime'], startPlace: d['startPlace'],
            finishPlace: d['finishPlace'], drops: d['drops'], nightOut: d['nightOut'], driving: d['driving'])],
      ),
      p2: P2Data(
        nameLine: p2['nameLine'], addr1: p2['addr1'], addr2: p2['addr2'], ni: p2['ni'], vehicle: p2['vehicle'], signedDate: p2['signedDate'],
        weDate: p2['weDate'], signature: sig,
        rows: [for (final r in p2['rows']) P2Row(place: r['place'], uk: r['uk'], eu: r['eu'], parking: n(r['parking']), parkingNote: r['parkingNote'],
            tolls: n(r['tolls']), tollsNote: r['tollsNote'], market: n(r['market']), marketNote: r['marketNote'], vat: n(r['vat']), total: n(r['total']))],
        totals: P2Totals(uk: p2['totals']['uk'], eu: p2['totals']['eu'], parking: n(p2['totals']['parking']), tolls: n(p2['totals']['tolls']),
            market: n(p2['totals']['market']), vat: n(p2['totals']['vat']), total: n(p2['totals']['total'])),
      ),
    );
    File(env['TUKI_PDF']!).writeAsBytesSync(bytes);
    if (env['TUKI_PDF_PRINT'] != null) { // the print layout, with a wide picture as a landscape receipt
      final logo = File('assets/cbt_logo.png').readAsBytesSync();
      File(env['TUKI_PDF_PRINT']!).writeAsBytesSync(await buildTimesheet(logo: logo, forPrint: true, p1: const P1Data(name: 'Print test'),
          attachments: [Attachment(logo), Attachment(sig)]));
      File('${env['TUKI_PDF_PRINT']!}.email.pdf').writeAsBytesSync(await buildTimesheet(logo: logo, p1: const P1Data(name: 'Email test'),
          attachments: [Attachment(logo), Attachment(sig)]));
    }
  }, skip: env['TUKI_SAMPLE'] == null ? 'set TUKI_SAMPLE, TUKI_SIG and TUKI_PDF' : false);
}
