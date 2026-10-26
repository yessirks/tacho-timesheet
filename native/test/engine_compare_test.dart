// Prints the same summary as the web engine (scratchpad js_weeks.js) for a real card file, so the
// Dart port can be diffed against tacho.js + week.js. Skipped unless TUKI_CARD and TUKI_OUT are set.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuki/core/tacho.dart';
import 'package:tuki/core/week.dart';

void main() {
  final cardPath = Platform.environment['TUKI_CARD'], outPath = Platform.environment['TUKI_OUT'];
  test('engine matches the web app', () {
    final card = parseCard(File(cardPath!).readAsBytesSync());
    final prep = prepare(card);
    final base = guessBase(prep);
    String f(Fix? x) => x == null ? '-' : '${x.pos.lat.toStringAsFixed(5)},${x.pos.lon.toStringAsFixed(5)},${x.src},${x.exact ? 1 : 0}';
    final out = <String>[
      'gen=${card.generation} days=${card.days.length} veh=${card.vehicles.length} places=${card.places.length} gnss=${card.gnssPlaces.length} borders=${card.borders.length} lu=${card.loadUnload.length} segs=${card.segments.length} shifts=${prep.shifts.length} fixes=${prep.fixes.length}',
      'base=${base == null ? '-' : '${base.lat.toStringAsFixed(5)},${base.lon.toStringAsFixed(5)}'}',
    ];
    for (final k in listWeeks(prep)) {
      final w = computeWeek(card, prep, k, base: base);
      out.add('week $k veh=${w.vehicle}');
      for (final r in w.rows) {
        if (!r.worked) { out.add('  ${r.date} -'); continue; }
        out.add('  ${r.date} ${r.startTime}-${r.finishTime} ${r.finishNote ?? ''} drv=${r.driving} work=${r.workMin.round()} night=${r.nightOut} s=${f(r.startFix)} e=${f(r.endFix)} '
            'drops=${r.drops.map((d) => '${d.time}${d.opName}').join('|')} stops=${r.stops.map((s) => '${s.label}:${s.work}').join('|')}');
      }
    }
    File(outPath!).writeAsStringSync('${out.join('\n')}\n');
  }, skip: cardPath == null || outPath == null ? 'set TUKI_CARD and TUKI_OUT' : false);
}
