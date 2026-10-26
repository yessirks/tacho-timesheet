// Driver card (.ddd / .c1b / .esm) parser — EU Regulation 165/2014, Annex 1B / 1C.
// Handles Gen1, Gen2 and Gen2v2 ("smart tachograph 2") card downloads.
// Everything is in UTC; the UI converts to UK time. Port of tacho.js.
import 'dart:typed_data';

const activityNames = ['Break/Rest', 'Availability', 'Work', 'Driving'];

const _nations = ['', 'A', 'AL', 'AND', 'ARM', 'AZ', 'B', 'BG', 'BIH', 'BY', 'CH', 'CY', 'CZ', 'D', 'DK', 'E',
  'EST', 'F', 'FIN', 'FL', 'FO', 'UK', 'GE', 'GR', 'H', 'HR', 'I', 'IRL', 'IS', 'KZ', 'L', 'LT', 'LV', 'M', 'MC',
  'MD', 'MK', 'N', 'NL', 'P', 'PL', 'RO', 'RSM', 'RUS', 'S', 'SK', 'SLO', 'TM', 'TR', 'UA', 'V', 'YU', 'MNE',
  'SRB', 'UZ', 'TJ', 'KG'];
String nation(int n) => n == 0xFD ? 'EC' : n == 0xFE ? 'EUR' : n == 0xFF ? 'WLD' : (n < _nations.length ? _nations[n] : '#$n');

const _placeEntry = ['Begin', 'End', 'Begin (manual)', 'End (manual)', 'Begin (assumed)', 'End (assumed)'];
const _loadOp = ['', 'Load', 'Unload', 'Load+Unload'];

// ---- byte helpers -----------------------------------------------------------
int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _u24(Uint8List b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
int _u32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _s24(Uint8List b, int o) { final v = _u24(b, o); return v & 0x800000 != 0 ? v - 0x1000000 : v; }
/// Seconds since 1970 → ms, or null for "no time".
int? _time(Uint8List b, int o) { final t = _u32(b, o); return t == 0 || t == 0xFFFFFFFF ? null : t * 1000; }
String _bcd(Uint8List b, int o, int n) { final s = StringBuffer(); for (var i = 0; i < n; i++) { s.write(b[o + i] >> 4); s.write(b[o + i] & 15); } return s.toString(); }
String _str(Uint8List b, int o, int n, bool hasCodepage) {
  // Strings are ISO-8859-x; we only need Latin letters, so decode as latin1.
  final s = StringBuffer();
  for (var i = hasCodepage ? 1 : 0; i < n; i++) { final c = b[o + i]; if (c != 0) s.writeCharCode(c); }
  return s.toString().trim();
}

class LatLon {
  final double lat, lon;
  const LatLon(this.lat, this.lon);
  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};
}

class Gnss extends LatLon {
  final int? time; final int accuracy;
  const Gnss(this.time, this.accuracy, double lat, double lon) : super(lat, lon);
}

// GNSS coordinates are ±DDMM.M × 10 (so 51450 = 51° 45.0').
double? _coord(int v) {
  if (v == 0x7FFFFF || v == -0x7FFFFF || v == 0x800000 || v == -0x800000) return null;
  final a = v.abs(), deg = a ~/ 1000, min = (a % 1000) / 10;
  return (v < 0 ? -1 : 1) * (deg + min / 60);
}
Gnss? _gnss(Uint8List b, int o) { // GNSSPlaceRecord: timeStamp(4) accuracy(1) lat(3) lon(3)
  final lat = _coord(_s24(b, o + 5)), lon = _coord(_s24(b, o + 8));
  if (lat == null || lon == null || (lat == 0 && lon == 0) || lat.abs() > 90 || lon.abs() > 180) return null;
  return Gnss(_time(b, o), b[o + 4], lat, lon);
}

class Identification {
  final String issuingNation, cardNumber, issuingAuthority, surname, firstNames, birthDate, language;
  final int? issueDate, validFrom, expiry;
  Identification(this.issuingNation, this.cardNumber, this.issuingAuthority, this.issueDate, this.validFrom, this.expiry,
      this.surname, this.firstNames, this.birthDate, this.language);
}

class ActivityChange {
  final int slot, crew, cardOut, activity, minute;
  ActivityChange(this.slot, this.crew, this.cardOut, this.activity, this.minute);
}

class CardDay {
  final int date; final String presence; final int distance; final List<ActivityChange> changes;
  CardDay(this.date, this.presence, this.distance, this.changes);
}

class Vehicle {
  final int odoBegin, odoEnd, firstUse; final int? lastUse; final String nation, reg, vin;
  Vehicle(this.odoBegin, this.odoEnd, this.firstUse, this.lastUse, this.nation, this.reg, this.vin);
}

class CardPlace {
  final int time, type, region, odo; final String typeName, country; final bool begin; final Gnss? gnss;
  CardPlace(this.time, this.type, this.typeName, this.begin, this.country, this.region, this.odo, this.gnss);
}

class GnssPlace { final int time; final Gnss? gnss; final int odo; GnssPlace(this.time, this.gnss, this.odo); }
class Border { final int time; final String left, entered; final Gnss gnss; final int odo; Border(this.time, this.left, this.entered, this.gnss, this.odo); }
class LoadUnload { final int time, op; final String opName; final Gnss? gnss; final int odo; LoadUnload(this.time, this.op, this.opName, this.gnss, this.odo); }

/// A continuous stretch of one activity, in UTC ms.
class Segment {
  final int start; int end; final int activity, cardOut, slot;
  Segment(this.start, this.end, this.activity, this.cardOut, this.slot);
}

class Card {
  final String generation;
  final Identification identification;
  final int? lastDownload;
  final List<CardDay> days;
  final List<Vehicle> vehicles;
  final List<CardPlace> places;
  final List<GnssPlace> gnssPlaces;
  final List<Border> borders;
  final List<LoadUnload> loadUnload;
  late final List<Segment> segments = buildSegments(days);
  Card(this.generation, this.identification, this.lastDownload, this.days, this.vehicles, this.places, this.gnssPlaces, this.borders, this.loadUnload);
}

// ---- container ----------------------------------------------------------------
// The .ddd is a list of: fileId(2) type(1) length(2) data.  type 0/1 = Gen1 data/signature, 2/3 = Gen2.
Map<String, Uint8List> _splitFiles(Uint8List buf) {
  final files = <String, Uint8List>{};
  var o = 0;
  while (o + 5 <= buf.length) {
    final fid = _u16(buf, o), type = buf[o + 2], len = _u16(buf, o + 3);
    if (o + 5 + len > buf.length) break;
    final gen = type >= 2 ? 2 : 1;
    if (type % 2 == 0) files['${fid.toRadixString(16).toUpperCase().padLeft(4, '0')}_$gen'] = Uint8List.sublistView(buf, o + 5, o + 5 + len);
    o += 5 + len;
  }
  return files;
}

// ---- individual files -----------------------------------------------------------
Identification _parseIdentification(Uint8List b) => Identification(
      nation(b[0]), _str(b, 1, 16, false), _str(b, 17, 36, true), _time(b, 53), _time(b, 57), _time(b, 61),
      _str(b, 65, 36, true), _str(b, 101, 36, true), _bcd(b, 137, 4), _str(b, 141, 2, false));

List<CardDay> _parseActivity(Uint8List b) {
  // CardDriverActivity: oldestDayPtr(2) newestRecordPtr(2) then a cyclic buffer of daily records.
  final oldest = _u16(b, 0), newest = _u16(b, 2), ring = Uint8List.sublistView(b, 4), n = ring.length;
  if (n == 0) return [];
  Uint8List rd(int pos, int len) { final out = Uint8List(len); for (var i = 0; i < len; i++) { out[i] = ring[(pos + i) % n]; } return out; }
  final days = <CardDay>[];
  var pos = newest, guard = 0;
  while (guard++ < 2000) {
    final head = rd(pos, 12);
    final prevLen = _u16(head, 0), len = _u16(head, 2);
    if (len < 12 || len > n) break;
    final rec = rd(pos, len), date = _time(rec, 4);
    if (date == null) break;
    final changes = <ActivityChange>[];
    for (var i = 12; i + 1 < len; i += 2) {
      final v = _u16(rec, i);
      changes.add(ActivityChange(v >> 15, (v >> 14) & 1, (v >> 13) & 1, (v >> 11) & 3, v & 0x7FF));
    }
    days.add(CardDay(date, _bcd(rec, 8, 2), _u16(rec, 10), changes));
    if (pos == oldest || prevLen == 0) break;
    pos = (pos - prevLen + n) % n;
  }
  return days.reversed.toList();
}

List<Vehicle> _parseVehicles(Uint8List b, int gen) {
  final size = gen == 2 ? 48 : 31, out = <Vehicle>[];
  for (var o = 2; o + size <= b.length; o += size) {
    final first = _time(b, o + 6), last = _time(b, o + 10);
    if (first == null) continue;
    out.add(Vehicle(_u24(b, o), _u24(b, o + 3), first, last, nation(b[o + 14]), _str(b, o + 15, 14, true), gen == 2 ? _str(b, o + 31, 17, false) : ''));
  }
  return out..sort((a, c) => a.firstUse.compareTo(c.firstUse));
}

List<CardPlace> _parsePlaces(Uint8List b, int gen) {
  final hdr = gen == 2 ? 2 : 1, size = gen == 2 ? 21 : 10, out = <CardPlace>[];
  for (var o = hdr; o + size <= b.length; o += size) {
    final t = _time(b, o);
    if (t == null) continue;
    final type = b[o + 4];
    out.add(CardPlace(t, type, type < _placeEntry.length ? _placeEntry[type] : '#$type', type % 2 == 0, nation(b[o + 5]), b[o + 6],
        _u24(b, o + 7), gen == 2 ? _gnss(b, o + 10) : null));
  }
  return out..sort((a, c) => a.time.compareTo(c.time));
}

List<GnssPlace> _parseGnssPlaces(Uint8List b) { // time(4) gnssPlace(11) odo(3), every 3h of driving
  final out = <GnssPlace>[];
  for (var o = 2; o + 18 <= b.length; o += 18) {
    final t = _time(b, o); if (t == null) continue;
    out.add(GnssPlace(t, _gnss(b, o + 4), _u24(b, o + 15)));
  }
  return out..sort((a, c) => a.time.compareTo(c.time));
}

List<Border> _parseBorders(Uint8List b) { // countryLeft(1) countryEntered(1) gnssAuth(12) odo(3)
  final out = <Border>[];
  for (var o = 2; o + 17 <= b.length; o += 17) {
    final g = _gnss(b, o + 2); if (g == null || g.time == null) continue;
    out.add(Border(g.time!, nation(b[o]), nation(b[o + 1]), g, _u24(b, o + 14)));
  }
  return out..sort((a, c) => a.time.compareTo(c.time));
}

List<LoadUnload> _parseLoadUnload(Uint8List b) { // time(4) opType(1) gnssAuth(12) odo(3)
  final out = <LoadUnload>[];
  for (var o = 2; o + 20 <= b.length; o += 20) {
    final t = _time(b, o); if (t == null) continue;
    final op = b[o + 4];
    out.add(LoadUnload(t, op, op < _loadOp.length ? _loadOp[op] : '?', _gnss(b, o + 5), _u24(b, o + 17)));
  }
  return out..sort((a, c) => a.time.compareTo(c.time));
}

// ---- timeline -------------------------------------------------------------------
// Flatten daily records into continuous segments, in UTC ms.
List<Segment> buildSegments(List<CardDay> days) {
  final segs = <Segment>[];
  for (final d in days) {
    final ch = d.changes;
    for (var i = 0; i < ch.length; i++) {
      final s = d.date + ch[i].minute * 60000;
      final e = i + 1 < ch.length ? d.date + ch[i + 1].minute * 60000 : d.date + 1440 * 60000;
      if (e <= s) continue;
      final last = segs.isEmpty ? null : segs.last;
      final a = ch[i].activity, out = ch[i].cardOut;
      if (last != null && last.end == s && last.activity == a && last.cardOut == out) {
        last.end = e;
      } else {
        segs.add(Segment(s, e, a, out, ch[i].slot));
      }
    }
  }
  return segs;
}

class Fix {
  final int? t; final LatLon pos; final String? country; final String src; final bool exact;
  const Fix({this.t, required this.pos, this.country, required this.src, this.exact = false});
  Fix copyWith({String? src, bool? exact}) => Fix(t: t, pos: pos, country: country, src: src ?? this.src, exact: exact ?? this.exact);
}

class Shift {
  final int start, cardIn; int end;
  final List<Segment> segs = [];
  double driving = 0, work = 0, availability = 0, breaks = 0;
  double restBefore = double.infinity, restAfter = double.infinity;
  Fix? startFix, endFix, lastFix;
  Shift(this.start, this.cardIn, this.end);
}

// A shift (duty period) ends when the driver has a rest/no-card gap of at least `minRestMin`.
List<Shift> buildShifts(List<Segment> segs, [int minRestMin = 420]) {
  final minRest = minRestMin * 60000;
  final shifts = <Shift>[];
  Shift? cur; int? restStart, cardInAt; Segment? prev;
  bool isRest(Segment s) => s.activity == 0 || s.cardOut == 1;
  for (final s in segs) {
    if (prev != null && prev.cardOut == 1 && s.cardOut == 0) cardInAt = s.start; // card inserted
    prev = s;
    if (isRest(s)) { restStart ??= s.start; continue; }
    if (cur != null && restStart != null && s.start - restStart >= minRest) { shifts.add(cur); cur = null; }
    if (cur == null) {
      // The working day starts when the card goes in (drivers copy this time from the tacho),
      // as long as that was shortly before the first activity.
      final cardIn = cardInAt != null && cardInAt <= s.start && s.start - cardInAt <= 3600000 ? cardInAt : s.start;
      cur = Shift(s.start, cardIn, s.end);
    }
    cur.end = s.end; cur.segs.add(s); restStart = null;
  }
  if (cur != null) shifts.add(cur);
  for (final sh in shifts) {
    final tot = [0.0, 0.0, 0.0, 0.0];
    for (final s in sh.segs) { tot[s.activity] += (s.end - s.start) / 60000; }
    sh.driving = tot[3]; sh.work = tot[2]; sh.availability = tot[1];
    // breaks inside the shift = span − active time
    sh.breaks = (sh.end - sh.start) / 60000 - tot[1] - tot[2] - tot[3];
  }
  return shifts;
}

Card parseCard(Uint8List buf) {
  final f = _splitFiles(buf);
  (Uint8List?, int) pick(String id) => f['${id}_2'] != null ? (f['${id}_2'], 2) : f['${id}_1'] != null ? (f['${id}_1'], 1) : (null, 0);
  final idB = pick('0520').$1;
  if (idB == null) throw const FormatException('This does not look like a driver card download (no identification block).');
  final actB = pick('0504').$1;
  final (vehB, vehGen) = pick('0505');
  final (plB, plGen) = pick('0506');
  final dl = pick('050E').$1;
  return Card(
    f['0501_2'] != null ? (f['0529_2'] != null ? '2v2' : '2') : '1',
    _parseIdentification(idB),
    dl != null ? _time(dl, 0) : null,
    actB != null ? _parseActivity(actB) : [],
    vehB != null ? _parseVehicles(vehB, vehGen) : [],
    plB != null ? _parsePlaces(plB, plGen) : [],
    f['0524_2'] != null ? _parseGnssPlaces(f['0524_2']!) : [],
    f['0528_2'] != null ? _parseBorders(f['0528_2']!) : [],
    f['0529_2'] != null ? _parseLoadUnload(f['0529_2']!) : [],
  );
}
