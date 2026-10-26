import 'package:flutter_test/flutter_test.dart';
import 'package:tuki/core/geo.dart';
import 'package:tuki/core/receipt.dart';
import 'package:tuki/core/timesheet_pdf.dart';
import 'package:tuki/core/week.dart';

void main() {
  test('reads coordinates out of links and text', () {
    final g = parseCoords('https://www.google.com/maps/place/Sainsbury%27s/@50.43,-3.57,17z/data=!3d50.4362!4d-3.5699')!;
    expect([g.lat, g.lon, g.name], [50.4362, -3.5699, "Sainsbury's"]);
    expect(parseCoords('50.4434, -4.6394')!.lon, -4.6394);
    expect(parseCoords('geo:51.5,-0.12?q=x')!.lat, 51.5);
    final d = parseCoords('''50°26'36.2"N 3°34'11.6"W''')!;
    expect(d.lat, closeTo(50.4434, 1e-3));
    expect(d.lon, closeTo(-3.5699, 1e-3));
    expect(parseCoords('no numbers here'), isNull);
    expect(isShortLink('https://maps.app.goo.gl/abc'), isTrue);
  });

  test('imports places from CSV and GPX', () {
    expect(parseImport('name,latitude,longitude,note\n"Gate, 2",50.1,-4.2,"ring bell"\n').single.name, 'Gate, 2');
    final gpx = parseImport('<gpx><wpt lat="50.5" lon="-4.1"><name>Depot</name></wpt></gpx>');
    expect([gpx.single.name, gpx.single.lat], ['Depot', 50.5]);
    expect(parseImport(toGPX([PlaceIO('A & B', 50.0, -4.0, 'x')])).single.name, 'A & B');
  });

  test('picks the total, VAT and kind from a receipt', () {
    final r = parseReceipt('GORDANO SERVICES\nLorry parking overnight\nNet 23.75\nVAT 20% 4.75\nTOTAL DUE £28.50\nVisa 28.50\n12/10/26');
    expect([r.amount, r.vat, r.kind, r.date], [28.5, 4.75, 'parking', '12/10/2026']);
    expect(parseReceipt('Greggs\nSausage roll 1.30\nCoffee 2.10\nTotal 3.40').kind, 'food');
  });

  test('UK dates and weeks', () {
    expect(sundayOfKey('2026-10-28'), '2026-10-25');
    expect(addDays('2026-10-25', 7), '2026-11-01');
    expect(dayIdx('2026-10-26'), 1);
    expect(hm(485), '8:05');
    // 23:30 UTC on a summer day is already the next day in the UK
    expect(localKey(DateTime.utc(2026, 7, 1, 23, 30).millisecondsSinceEpoch), '2026-07-02');
  });

  test('builds a timesheet PDF', () async {
    final b = await buildTimesheet(p1: const P1Data(name: 'Test', days: [P1Day(startTime: '05:00', drops: 'A, B')]));
    expect(String.fromCharCodes(b.take(5)), '%PDF-');
    expect(b.length, greaterThan(3000));
  });
}
