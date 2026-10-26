// Turns parsed card data into the 7 rows of a Sunday–Saturday timesheet (UK time). Port of week.js.
import 'dart:math' as math;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'tacho.dart';

const dowShort = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const _min = 60000, _hour = 3600000, _day = 86400000;

tz.Location? _london;
tz.Location get london {
  if (_london == null) { tzdata.initializeTimeZones(); _london = tz.getLocation('Europe/London'); }
  return _london!;
}

class LocalTime {
  final int y, m, d, dow; final String hh, mm;
  LocalTime(this.y, this.m, this.d, this.dow, this.hh, this.mm);
  String get time => '$hh:$mm';
}

LocalTime local(int ms) {
  final t = tz.TZDateTime.fromMillisecondsSinceEpoch(london, ms);
  return LocalTime(t.year, t.month, t.day, t.weekday % 7, t.hour.toString().padLeft(2, '0'), t.minute.toString().padLeft(2, '0'));
}

// Calendar dates are handled as "YYYY-MM-DD" keys; arithmetic is done on UTC midnights.
String keyOf(int y, int m, int d) => DateTime.utc(y, m, d).toIso8601String().substring(0, 10);
int keyMs(String key) => DateTime.parse('${key}T00:00:00Z').millisecondsSinceEpoch;
String addDays(String key, int n) => DateTime.fromMillisecondsSinceEpoch(keyMs(key) + n * _day, isUtc: true).toIso8601String().substring(0, 10);
String localKey(int ms) { final l = local(ms); return keyOf(l.y, l.m, l.d); }
String sundayOf(int ms) { final l = local(ms); return keyOf(l.y, l.m, l.d - l.dow); }
String sundayOfKey(String key) => sundayOf(keyMs(key) + 12 * _hour);
int dayDiff(String a, String b) => ((keyMs(b) - keyMs(a)) / _day).round();
int dayIdx(String key) => DateTime.parse('${key}T00:00:00Z').weekday % 7;
String todayKey() => localKey(DateTime.now().millisecondsSinceEpoch);

double distKm(LatLon a, LatLon b) {
  const r = 6371.0, rad = math.pi / 180;
  final dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(a.lat * rad) * math.cos(b.lat * rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

String hm(num min) => '${(min / 60).floor()}:${(min % 60).round().toString().padLeft(2, '0')}';

// Every GNSS fix on the card, for "where was the truck around time t" lookups.
List<Fix> allFixes(Card card) {
  final out = <Fix>[
    for (final p in card.places) if (p.gnss != null) Fix(t: p.time, pos: p.gnss!, country: p.country, src: 'place'),
    for (final g in card.gnssPlaces) if (g.gnss != null) Fix(t: g.time, pos: g.gnss!, src: '3h'),
    for (final l in card.loadUnload) if (l.gnss != null) Fix(t: l.time, pos: l.gnss!, src: 'load'),
    for (final b in card.borders) Fix(t: b.time, pos: b.gnss, country: b.entered, src: 'border'),
  ];
  return out..sort((a, b) => a.t!.compareTo(b.t!));
}

class Prepared { final List<Shift> shifts; final List<Fix> fixes; Prepared(this.shifts, this.fixes); }

Prepared prepare(Card card, {int minRestMin = 420}) {
  final shifts = buildShifts(card.segments, minRestMin);
  final fixes = allFixes(card);
  Fix? near(int t, int before, int after) {
    Fix? best;
    for (final f in fixes) {
      if (f.t! >= t - before && f.t! <= t + after && (best == null || (f.t! - t).abs() < (best.t! - t).abs())) best = f;
    }
    return best;
  }
  CardPlace? findPlace(bool begin, int t) {
    for (final p in card.places) { if (p.begin == begin && p.gnss != null && (p.time - t).abs() <= 45 * _min) return p; }
    return null;
  }
  for (var i = 0; i < shifts.length; i++) {
    final sh = shifts[i], start = sh.cardIn;
    sh.restBefore = i > 0 ? (start - shifts[i - 1].end).toDouble() : double.infinity;
    sh.restAfter = i + 1 < shifts.length ? (shifts[i + 1].cardIn - sh.end).toDouble() : double.infinity;
    final b = findPlace(true, start), e = findPlace(false, sh.end);
    sh.startFix = b != null ? Fix(pos: b.gnss!, country: b.country, src: 'place') : null;
    sh.endFix = e != null ? Fix(pos: e.gnss!, country: e.country, src: 'place') : near(sh.end, 45 * _min, 5 * _min);
    sh.lastFix = sh.endFix ?? fixes.reversed.cast<Fix?>().firstWhere((f) => f!.t! <= sh.end && f.t! >= start, orElse: () => null);
  }
  // "exact" = a begin/end place record, or a fix within 5 minutes; anything else is only a hint.
  bool ex(Fix f, int t) => f.src == 'place' || (f.t != null && (f.t! - t).abs() <= 5 * _min);
  for (final sh in shifts) {
    if (sh.startFix != null) sh.startFix = sh.startFix!.copyWith(exact: ex(sh.startFix!, sh.cardIn));
    if (sh.endFix != null) sh.endFix = sh.endFix!.copyWith(exact: ex(sh.endFix!, sh.end));
  }
  for (var i = 0; i < shifts.length; i++) { // truck usually hasn't moved overnight
    final sh = shifts[i];
    if (sh.startFix == null && i > 0 && sh.restBefore < 20 * _hour && shifts[i - 1].endFix != null) sh.startFix = shifts[i - 1].endFix!.copyWith(src: 'prev');
    if (sh.startFix == null) {
      final f = near(sh.cardIn, 5 * _min, 45 * _min);
      if (f != null) sh.startFix = f.copyWith(exact: ex(f, sh.cardIn));
    }
  }
  return Prepared(shifts, fixes);
}

// Home base = where weekly rests (24h+) are taken, unless the user set one.
LatLon? guessBase(Prepared prep) {
  final pts = prep.shifts.where((s) => s.restAfter >= 24 * _hour && s.restAfter != double.infinity && s.endFix != null).map((s) => s.endFix!.pos).toList();
  LatLon? best; var bestN = 0;
  for (final p in pts) { final n = pts.where((q) => distKm(p, q) < 2).length; if (n > bestN) { best = p; bestN = n; } }
  return best;
}

List<String> listWeeks(Prepared prep) => ({for (final s in prep.shifts) sundayOf(s.cardIn)}.toList()..sort()).reversed.toList();

class WorkStop { final int from, to, work, rest; final String label; WorkStop(this.from, this.to, this.work, this.rest, this.label); }

// Stops between "real" drives (driving ≥ 4 min); shows the driver where the drops probably were.
List<WorkStop> stopsOf(Shift sh) {
  final drives = sh.segs.where((s) => s.activity == 3 && s.end - s.start >= 4 * _min).toList();
  final stops = <WorkStop>[];
  for (var i = 0; i + 1 < drives.length; i++) {
    final a = drives[i].end, b = drives[i + 1].start;
    if (b - a < 10 * _min) continue;
    var work = 0.0, rest = 0.0;
    for (final s in sh.segs) {
      final o = math.max(0, math.min(b, s.end) - math.max(a, s.start)) / _min;
      if (o == 0) continue;
      if (s.activity == 2 || s.activity == 1) { work += o; } else if (s.activity == 0) { rest += o; }
    }
    // Pure breaks (no work) are not drops.
    if (work >= 5) stops.add(WorkStop(a, b, work.round(), rest.round(), '${local(a).time}–${local(b).time}'));
  }
  return stops;
}

class GpsDrop { final int time, op; final String opName; final LatLon? pos; GpsDrop(this.time, this.op, this.opName, this.pos); }

class DayRow {
  final String date;
  final List<Shift> shifts = [];
  List<GpsDrop> drops = [];
  List<WorkStop> stops = [];
  int? start, end;
  String? startTime, finishTime, finishNote, driving, nightOut;
  Fix? startFix, endFix;
  double drivingMin = 0, workMin = 0;
  DayRow(this.date);
  bool get worked => startTime != null;
}

class WeekResult { final String sunday, saturday, vehicle; final List<DayRow> rows; WeekResult(this.sunday, this.saturday, this.rows, this.vehicle); }

WeekResult computeWeek(Card card, Prepared prep, String sundayKey, {LatLon? base, double awayKm = 25}) {
  final rows = List.generate(7, (i) => DayRow(addDays(sundayKey, i)));
  for (final sh in prep.shifts) {
    final idx = dayDiff(sundayKey, localKey(sh.cardIn));
    if (idx >= 0 && idx < 7) rows[idx].shifts.add(sh);
  }
  for (final r in rows) {
    if (r.shifts.isEmpty) continue;
    final first = r.shifts.first, last = r.shifts.last;
    r.start = first.cardIn; r.end = last.end;
    r.startTime = local(r.start!).time; r.finishTime = local(r.end!).time;
    if (localKey(r.end!) != r.date) r.finishNote = 'next day';
    r.startFix = first.startFix; r.endFix = last.endFix;
    r.drivingMin = r.shifts.fold(0.0, (a, s) => a + s.driving);
    r.driving = hm(r.drivingMin);
    r.workMin = r.shifts.fold(0.0, (a, s) => a + s.work + s.availability);
    r.drops = [for (final l in card.loadUnload) if (l.time >= r.start! - 10 * _min && l.time <= r.end! + 10 * _min) GpsDrop(l.time, l.op, l.opName, l.gnss)];
    r.stops = r.shifts.expand(stopsOf).toList();
    // Night out: the day ends away from base, and it isn't the start of a weekly rest at home.
    final endPos = (last.endFix ?? last.lastFix)?.pos;
    final bool? away = base != null && endPos != null ? distKm(base, endPos) > awayKm : null;
    // An exact end-of-day place decides it; a rough position only counts if no weekly rest follows.
    final exact = last.endFix != null && last.endFix!.src == 'place';
    final isOut = exact ? away == true : (last.restAfter < 24 * _hour && away != false);
    r.nightOut = isOut ? 'UK' : '';
    final ctry = last.endFix?.country ?? '';
    if (r.nightOut!.isNotEmpty && ctry.isNotEmpty && ctry != 'UK') r.nightOut = 'EU';
  }
  // Vehicle(s), most used first.
  final ws = keyMs(sundayKey) - 2 * _hour, we = ws + 7 * _day + 4 * _hour;
  final use = <String, int>{};
  for (final v in card.vehicles) {
    final a = math.max(ws, v.firstUse), b = math.min(we, v.lastUse ?? v.firstUse);
    if (b > a) use[v.reg] = (use[v.reg] ?? 0) + (b - a);
  }
  final vehicle = (use.keys.toList()..sort((a, b) => use[b]!.compareTo(use[a]!))).join(' / ');
  return WeekResult(sundayKey, addDays(sundayKey, 6), rows, vehicle);
}
