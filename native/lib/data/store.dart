// App state and the logic that joins the tacho, your diary and your edits (port of app.js).
// Data is kept in the same JSON shapes as the web app, so its backup file imports as-is.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../core/geo.dart' as geo;
import '../core/tacho.dart';
import '../core/week.dart';

typedef J = Map<String, dynamic>;

const dayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const expenseTypes = {'parking': 'Parking', 'tolls': 'Bridge / toll', 'food': 'Food', 'market': 'Other'};
const stopTypes = {'drop': 'Drop', 'pickup': 'Pickup', 'couple': 'Couple', 'uncouple': 'Uncouple', 'other': 'Other'};
const dayKeys = ['startTime', 'finishTime', 'startPlace', 'finishPlace', 'drops', 'nightOut', 'driving', 'stayed'];
const profileKeys = ['name', 'nameLine', 'addr1', 'addr2', 'ni', 'declaration', 'page2'];
const diaryField = {'startPlace': 'start', 'finishPlace': 'finish'};
const fillOptions = {'times': 'Start/finish times', 'places': 'Places', 'drops': 'Drops (Load/Unload GPS)', 'nightOut': 'Nights out',
  'driving': 'Driving hours', 'stayed': 'Page 2 "Place"', 'vehicle': 'Vehicle reg', 'totals': 'Totals & 24hr away'};

// Sites that OpenStreetMap doesn't name well. Your own saved places win over these.
const knownPlaces = [
  {'name': 'Trewithen Dairy', 'lat': 50.4434, 'lon': -4.6394, 'radius': 700},
  {'name': 'Dunbia Treburley', 'lat': 50.5753, 'lon': -4.3330, 'radius': 900},
  {'name': 'Ornua Foods Leek', 'lat': 53.0961, 'lon': -2.0348, 'radius': 600},
  {'name': 'Gordano Services', 'lat': 51.4762, 'lon': -2.7080, 'radius': 600},
];

String uid() { final r = math.Random(); return List.generate(8, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join(); }
double numOf(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? double.nan;
double money(dynamic v) { final x = numOf(v); return x.isNaN ? 0 : x; }
bool hasLL(J m) => numOf(m['lat']).isFinite && numOf(m['lon']).isFinite;

// ---- dates -------------------------------------------------------------------
String ord(int n) => '$n${n % 10 == 1 && n != 11 ? 'st' : n % 10 == 2 && n != 12 ? 'nd' : n % 10 == 3 && n != 13 ? 'rd' : 'th'}';
(int, int, int) parts(String key) { final p = key.split('-').map(int.parse).toList(); return (p[0], p[1], p[2]); }
String fmtLong(String key) { final (y, m, d) = parts(key); return '${ord(d)} ${monthNames[m - 1]} $y'; }
String fmtShort(String key) { final (y, m, d) = parts(key); return '${d.toString().padLeft(2, '0')}/${m.toString().padLeft(2, '0')}/$y'; }
String fmtDay(String key) { final (_, m, d) = parts(key); return '$d ${monthNames[m - 1].substring(0, 3)}'; }
String geoKey(double lat, double lon) => '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';
String coordText(LatLon? p) => p == null ? '' : '${p.lat.toStringAsFixed(4)}, ${p.lon.toStringAsFixed(4)}';

class Pos { final double lat, lon, acc; final int t; const Pos(this.lat, this.lon, [this.acc = 0, this.t = 0]); LatLon get ll => LatLon(lat, lon); }

class Suggestion {
  final String name, icon; String sub; final double? lat, lon; final int w, c, nx; final double? d; final int sc;
  Suggestion(this.name, this.sub, this.icon, {this.lat, this.lon, this.w = 0, this.c = 0, this.d, this.sc = 0, this.nx = 0});
}

class NearVisit { final String name, src, time; final double lat, lon; NearVisit(this.name, this.lat, this.lon, this.src, this.time); }

class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore I = AppStore._();

  late Directory dir;
  bool ready = false;
  J profile = {};
  List<J> places = [], stars = [];
  Map<String, J> diary = {};
  Map<String, J> geoCache = {};
  Map<String, List<J>> visits = {};
  Map<String, J> weeks = {}; // sunday key -> week state
  Card? card; Prepared? prep; String cardName = '';
  Pos? lastPos;
  String status = '';
  final _weekCache = <String, WeekResult>{};

  // ---- persistence -------------------------------------------------------------
  File get _file => File('${dir.path}/tuki.json');
  File get _cardFile => File('${dir.path}/card.ddd');
  Directory get attDir => Directory('${dir.path}/att');

  Future<void> load({String? demo}) async {
    if (kIsWeb) { // browser preview: no phone storage, start from sample data
      if (demo != null) importAll(demo);
      ready = true;
      notifyListeners();
      return;
    }
    dir = await getApplicationDocumentsDirectory();
    await attDir.create(recursive: true);
    if (await _file.exists()) {
      try { _apply(jsonDecode(await _file.readAsString()) as J); } catch (e) { debugPrint('load failed $e'); }
    }
    if (await _cardFile.exists()) {
      try { _setCard(await _cardFile.readAsBytes(), (profile['_cardName'] ?? 'card.ddd') as String); } catch (e) { debugPrint('card failed $e'); }
    }
    ready = true;
    notifyListeners();
  }

  void _apply(J j) {
    profile = (j['profile'] ?? {}) as J;
    places = [for (final p in (j['places'] ?? []) as List) Map<String, dynamic>.from(p as Map)];
    stars = [for (final p in (j['stars'] ?? []) as List) Map<String, dynamic>.from(p as Map)];
    diary = {for (final e in ((j['diary'] ?? {}) as Map).entries) e.key as String: _normalizeEntry(e.value)};
    geoCache = {for (final e in ((j['geo'] ?? {}) as Map).entries) e.key as String: Map<String, dynamic>.from(e.value as Map)};
    visits = {for (final e in ((j['visits'] ?? {}) as Map).entries) e.key as String: [for (final v in e.value as List) Map<String, dynamic>.from(v as Map)]};
    weeks = {for (final e in ((j['weeks'] ?? {}) as Map).entries) (e.key as String).replaceFirst('week:', ''): _normalizeWeek(e.value as Map)};
  }

  J _toJson({bool forExport = false}) => {
        'app': 'tacho-timesheet', 'version': 4, 'exported': DateTime.now().toUtc().toIso8601String(),
        'profile': forExport ? ({...profile}..remove('_cardName')) : profile,
        'places': places, 'stars': stars, 'diary': diary, 'geo': geoCache,
        if (!forExport) 'visits': visits,
        'weeks': {for (final e in weeks.entries) 'week:${e.key}': forExport ? _stripPhotos(e.value) : e.value},
      };

  Timer? _saveT;
  /// Saves soon (batched) and redraws.
  void changed() { _weekCache.clear(); notifyListeners(); _saveT?.cancel(); _saveT = Timer(const Duration(milliseconds: 400), saveNow); }
  Future<void> saveNow() async {
    _saveT?.cancel();
    if (kIsWeb) return;
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_toJson()));
    await tmp.rename(_file.path);
  }

  // Older versions stored drops as one line of text; turn it into the typed list.
  static List<J> parseStops(String text) => text.split(RegExp(r'[,\n]+')).map((t) => t.trim()).where((t) => t.isNotEmpty).map<J>((t) {
        RegExpMatch? m;
        if ((m = RegExp(r'^(?:load(?:ed)?(?: from)?|pick ?up|collect(?:ion)?)[:\s]+(.+)', caseSensitive: false).firstMatch(t)) != null) return {'type': 'pickup', 'name': m![1]};
        if ((m = RegExp(r'^uncoupl\w*[:\s]+(.+)', caseSensitive: false).firstMatch(t)) != null) return {'type': 'uncouple', 'name': m![1]};
        if ((m = RegExp(r'^coupl\w*[:\s]+(.+)', caseSensitive: false).firstMatch(t)) != null) return {'type': 'couple', 'name': m![1]};
        if ((m = RegExp(r'^drop(?:ped)?[:\s]+(.+)', caseSensitive: false).firstMatch(t)) != null) return {'type': 'drop', 'name': m![1]};
        return {'type': 'drop', 'name': t};
      }).toList();

  static J _normalizeEntry(dynamic e) {
    final J o = e is String ? {'drops': e} : Map<String, dynamic>.from(e as Map);
    if (o['drops'] is String) { o['stops'] ??= parseStops(o['drops'] as String); o.remove('drops'); }
    if (o['stops'] is List) o['stops'] = [for (final s in o['stops'] as List) Map<String, dynamic>.from(s as Map)];
    return o;
  }

  static J _normalizeWeek(Map w) => {
        ...Map<String, dynamic>.from(w),
        'days': [for (var i = 0; i < 7; i++) Map<String, dynamic>.from(((w['days'] as List?) ?? const [])
            .elementAtOrNull(i) as Map? ?? {})],
        'foot': Map<String, dynamic>.from((w['foot'] ?? {}) as Map),
        'expenses': [for (final e in (w['expenses'] ?? []) as List) Map<String, dynamic>.from(e as Map)],
        'other': [for (final e in (w['other'] ?? []) as List) Map<String, dynamic>.from(e as Map)],
      };

  static J _stripPhotos(J w) => {
        ...w,
        'expenses': [for (final e in w['expenses'] as List) () { final m = Map<String, dynamic>.from(e as Map); final att = m.remove('att'); if (att != null) m['photo'] = att['name']; return m; }()],
        'other': [],
      };

  String exportAll() => const JsonEncoder.withIndent(' ').convert(_toJson(forExport: true));

  /// Merge, so restoring never wipes a signature, places or entries already on this device.
  void importAll(String text) {
    final j = jsonDecode(text) as J;
    if (j['profile'] is Map) profile = {...profile, ...Map<String, dynamic>.from(j['profile'] as Map)};
    if (j['places'] is List) {
      for (final p0 in j['places'] as List) {
        final p = Map<String, dynamic>.from(p0 as Map);
        final same = places.where((q) => distKm(LatLon(numOf(q['lat']), numOf(q['lon'])), LatLon(numOf(p['lat']), numOf(p['lon']))) < 0.2).firstOrNull;
        if (same != null) { same.addAll(p); } else { places.add(p); }
      }
      final b = (j['places'] as List).cast<Map>().where((p) => p['base'] == true).firstOrNull;
      if (b != null) { for (final q in places) { q['base'] = distKm(LatLon(numOf(q['lat']), numOf(q['lon'])), LatLon(numOf(b['lat']), numOf(b['lon']))) < 0.2; } }
    }
    if (j['diary'] is Map) {
      for (final e in (j['diary'] as Map).entries) { diary[e.key as String] = {..._normalizeEntry(e.value), ...?diary[e.key]}; }
    }
    if (j['geo'] is Map) { for (final e in (j['geo'] as Map).entries) { geoCache[e.key as String] = Map<String, dynamic>.from(e.value as Map); } }
    if (j['stars'] is List) { for (final s in j['stars'] as List) { addStar(Map<String, dynamic>.from(s as Map), save: false); } }
    if (j['weeks'] is Map) {
      for (final e in (j['weeks'] as Map).entries) {
        final k = (e.key as String).replaceFirst('week:', ''), v = _normalizeWeek(e.value as Map);
        final cur = weeks[k];
        if (cur == null) { weeks[k] = v; continue; }
        for (var i = 0; i < 7; i++) { cur['days'][i] = <String, dynamic>{...v['days'][i] as Map, ...cur['days'][i] as Map}; }
        cur['foot'] = <String, dynamic>{...v['foot'] as Map, ...cur['foot'] as Map};
        for (final x in v['expenses'] as List) { if (!(cur['expenses'] as List).any((y) => y['id'] == x['id'])) (cur['expenses'] as List).add(x); }
      }
    }
    changed();
  }

  // ---- card --------------------------------------------------------------------
  void _setCard(Uint8List bytes, String name) {
    card = parseCard(bytes);
    prep = prepare(card!);
    cardName = name;
    if (basePlace == null) {
      final b = guessBase(prep!);
      if (b != null) places.add({'id': uid(), 'name': '', 'lat': b.lat, 'lon': b.lon, 'radius': 1500, 'base': true});
    }
  }

  /// Throws a FormatException when the file isn't a driver card.
  Future<void> loadCard(Uint8List bytes, String name) async {
    _setCard(bytes, name);
    await _cardFile.writeAsBytes(bytes);
    profile['_cardName'] = name;
    changed();
  }

  List<String> weekKeys() {
    final w = prep != null ? listWeeks(prep!) : <String>[];
    final s = sundayOf(DateTime.now().millisecondsSinceEpoch);
    final recent = List.generate(12, (i) => addDays(s, -7 * i));
    return ({...w, ...recent}.toList()..sort()).reversed.toList();
  }

  int shiftsIn(String sun) => prep?.shifts.where((s) => sundayOf(s.cardIn) == sun).length ?? 0;

  // ---- places / geocoding ----------------------------------------------------------
  J? get basePlace => places.where((p) => p['base'] == true).firstOrNull;
  LatLon? get baseLL { final b = basePlace; return b == null ? null : LatLon(numOf(b['lat']), numOf(b['lon'])); }

  J? savedAt(LatLon pos, {bool mineOnly = false}) {
    J? pick(Iterable<J> list, double defR) {
      J? best; var bd = double.infinity;
      for (final p in list) {
        final d = distKm(LatLon(numOf(p['lat']), numOf(p['lon'])), pos) * 1000;
        if (d <= (p['radius'] as num? ?? defR) && d < bd) { best = p; bd = d; }
      }
      return best;
    }
    final mine = pick(places, 500);
    if (mine != null && (mine['name'] ?? '').toString().isNotEmpty) return mine;
    if (mineOnly) return mine;
    return pick(stars, 200) ?? pick(knownPlaces.map((p) => Map<String, dynamic>.from(p)), 500) ?? mine;
  }

  final _geoQueue = <LatLon>[];
  final _geoFailed = <String>{};
  bool _geoBusy = false;

  String label(LatLon? pos) {
    if (pos == null) return '';
    final sp = savedAt(pos);
    if (sp != null && (sp['name'] ?? '').toString().isNotEmpty) return sp['name'] as String;
    final k = geoKey(pos.lat, pos.lon), g = geoCache[k];
    if (g != null) return (g['label'] ?? '') as String;
    if (profile['geocode'] != 'no' && !_geoFailed.contains(k) && !_geoQueue.any((q) => geoKey(q.lat, q.lon) == k)) { _geoQueue.add(pos); _pumpGeo(); }
    return '';
  }

  String? geoDisplay(LatLon? pos) => pos == null ? null : geoCache[geoKey(pos.lat, pos.lon)]?['display'] as String?;

  Future<void> _pumpGeo() async {
    if (_geoBusy) return;
    _geoBusy = true;
    while (_geoQueue.isNotEmpty) {
      final pos = _geoQueue.first, k = geoKey(pos.lat, pos.lon);
      status = 'Looking up ${_geoQueue.length} place name${_geoQueue.length > 1 ? 's' : ''}…';
      notifyListeners();
      if (geoCache[k] == null) {
        try { geoCache[k] = (await geo.labelFor(pos.lat, pos.lon)).toJson(); } catch (e) { _geoFailed.add(k); }
        await Future.delayed(const Duration(milliseconds: 1100)); // Nominatim allows 1 request/second
      }
      _geoQueue.removeAt(0);
      changed();
    }
    _geoBusy = false;
    status = '';
    notifyListeners();
  }

  void learnPlace(LatLon pos, String name) {
    final sp = savedAt(pos, mineOnly: true);
    if (sp != null) { sp['name'] = name; } else { places.add({'id': uid(), 'name': name, 'lat': pos.lat, 'lon': pos.lon, 'radius': 500, 'base': false}); }
    changed();
  }

  void addStar(J p, {bool save = true}) {
    final same = stars.where((s) => (s['name'] ?? '').toString().toLowerCase() == (p['name'] ?? '').toString().toLowerCase() &&
        geo.distM(numOf(s['lat']), numOf(s['lon']), numOf(p['lat']), numOf(p['lon'])) < 25).firstOrNull;
    if (same != null) { same.addAll(p); } else { stars.add({'id': uid(), 'note': '', ...p}); }
    if (save) changed();
  }

  void removeStar(String id) { stars.removeWhere((s) => s['id'] == id); changed(); }

  // ---- values: tacho (auto) + your edits ------------------------------------------------
  bool on(String k) => profile['fill'] is! Map || (profile['fill'] as Map)[k] != false;
  double get awayKm => numOf(profile['awayKm']).isFinite && numOf(profile['awayKm']) > 0 ? numOf(profile['awayKm']) : 25;

  WeekResult? tachoWeek(String sun) {
    if (card == null) return null;
    return _weekCache[sun] ??= computeWeek(card!, prep!, sun, base: baseLL, awayKm: awayKm);
  }

  /// The timesheet row the tacho gives for any date.
  DayRow? tachoDay(String date) { final r = tachoWeek(sundayOfKey(date))?.rows[dayIdx(date)]; return r != null && r.worked ? r : null; }

  J weekState(String sun) => weeks[sun] ??= _normalizeWeek({});

  J dget(String date) => diary[date] ?? const {};

  void setDiary(String date, String field, dynamic v) {
    final e = {...dget(date)};
    final empty = v is List ? v.isEmpty : (v == null || v.toString().trim().isEmpty);
    if (empty) { e.remove(field); } else { e[field] = v; }
    if (e.isNotEmpty) { diary[date] = e; } else { diary.remove(date); }
    final w = weeks[sundayOfKey(date)];
    if (w != null) w['editedAt'] = DateTime.now().millisecondsSinceEpoch;
    changed();
  }

  List<J> stopsOn(String date) => [for (final s in (dget(date)['stops'] ?? const []) as List) Map<String, dynamic>.from(s as Map)];
  void setStops(String date, List<J> list) => setDiary(date, 'stops', list);

  // On the timesheet a drop is just its name, like you'd write it; the others say what happened.
  String fmtStop(J s) {
    final name = (s['name'] ?? '').toString().trim(), ref = (s['ref'] ?? '').toString().trim(), type = (s['type'] ?? 'drop') as String;
    if (name.isEmpty && ref.isEmpty) return '';
    if ((type == 'couple' || type == 'uncouple') && ref.isNotEmpty) return '${stopTypes[type]} $ref${name.isNotEmpty ? ' @ $name' : ''}';
    final what = name.isNotEmpty && ref.isNotEmpty ? '$name ($ref)' : name.isNotEmpty ? name : ref;
    return (type == 'drop' && profile['dropWord'] != 'yes') || type == 'other' ? what : '${stopTypes[type] ?? ''} $what';
  }
  String fmtStops(List? list) => (list ?? const []).map((s) => fmtStop(Map<String, dynamic>.from(s as Map))).where((x) => x.isNotEmpty).join(', ');
  List<J> gpsStops(DayRow r) => [for (final d in r.drops) {'type': d.op == 1 ? 'pickup' : 'drop', 'name': label(d.pos).isEmpty ? '…' : label(d.pos)}];
  String fixLabel(Fix? f) => f != null && f.exact ? label(f.pos) : '';

  /// Which trailer is on at a point in the diary: "Couple 123" sets it, "Uncouple" clears it (carries across days).
  ({String ref, String date, String at})? trailerBefore(String date, int idx) {
    ({String ref, String date, String at})? cur;
    final from = addDays(date, -45);
    for (final d in (diary.keys.where((k) => k.compareTo(from) >= 0 && k.compareTo(date) <= 0).toList()..sort())) {
      final list = (diary[d]!['stops'] ?? const []) as List, end = d == date ? math.min(idx, list.length) : list.length;
      for (var i = 0; i < end; i++) {
        final x = list[i] as Map, ref = (x['ref'] ?? '').toString().trim();
        if (x['type'] == 'couple' && ref.isNotEmpty) { cur = (ref: ref, date: d, at: (x['name'] ?? '').toString().trim()); }
        else if (x['type'] == 'uncouple') { cur = null; }
      }
    }
    return cur;
  }

  J autoDay(String sun, int i) {
    final date = addDays(sun, i), r = tachoWeek(sun)?.rows[i], n = dget(date);
    if (r == null || !r.worked) {
      return {'startTime': '', 'finishTime': '', 'startPlace': n['start'] ?? '', 'finishPlace': n['finish'] ?? '', 'drops': fmtStops(n['stops'] as List?), 'nightOut': '', 'driving': '', 'stayed': ''};
    }
    // Only exact positions are filled in; rough ones are shown as a hint in the empty field.
    String at(Fix? f) => on('places') && f != null && f.exact ? label(f.pos) : '';
    final mine = fmtStops(n['stops'] as List?);
    return {
      'startTime': on('times') ? r.startTime : '', 'finishTime': on('times') ? r.finishTime : '',
      // What you wrote in the diary wins; otherwise the tacho's GPS places and Load/Unload drops.
      'startPlace': (n['start'] as String?)?.isNotEmpty == true ? n['start'] : at(r.startFix),
      'finishPlace': (n['finish'] as String?)?.isNotEmpty == true ? n['finish'] : at(r.endFix),
      'drops': mine.isNotEmpty ? mine : (on('drops') ? fmtStops(gpsStops(r)) : ''),
      'nightOut': on('nightOut') ? r.nightOut : '', 'driving': on('driving') ? r.driving : '', 'stayed': '',
    };
  }

  String dayVal(String sun, int i, String k) {
    final o = weekState(sun)['days'][i] as Map;
    if (o.containsKey(k)) return (o[k] ?? '').toString();
    if (k == 'stayed') return on('stayed') && dayVal(sun, i, 'nightOut').isNotEmpty ? dayVal(sun, i, 'finishPlace') : '';
    return (autoDay(sun, i)[k] ?? '').toString();
  }

  bool dayEdited(String sun, int i, String k) {
    final f = diaryField[k];
    if (f != null) return (dget(addDays(sun, i))[f] ?? '').toString().isNotEmpty;
    return (weekState(sun)['days'][i] as Map).containsKey(k);
  }

  void setDayVal(String sun, int i, String k, String v) {
    final f = diaryField[k];
    if (f != null) { setDiary(addDays(sun, i), f, v); return; }
    final w = weekState(sun);
    (w['days'][i] as Map)[k] = v;
    w['editedAt'] = DateTime.now().millisecondsSinceEpoch;
    changed();
  }

  void resetDay(String sun, int i) { weekState(sun)['days'][i] = <String, dynamic>{}; changed(); }

  J autoFoot(String sun) {
    final worked = List.generate(7, (i) => dayVal(sun, i, 'startTime').isNotEmpty || dayVal(sun, i, 'finishTime').isNotEmpty);
    final id = card?.identification, totals = on('totals');
    return {
      'totalWeekdays': totals ? '${worked.sublist(1, 6).where((x) => x).length}' : '',
      'totalWeekendDays': totals ? '${(worked[0] ? 1 : 0) + (worked[6] ? 1 : 0)}' : '',
      'away24': totals ? (List.generate(7, (i) => dayVal(sun, i, 'nightOut').isNotEmpty).any((x) => x) ? 'YES' : 'NO') : '',
      'declaration': '',
      'name': id != null ? '${id.surname} ${id.firstNames}' : '',
      'weekCommencing': fmtLong(sun),
      'nameLine': id != null ? '${id.firstNames} ${id.surname}'.toUpperCase() : '',
      'addr1': '', 'addr2': '', 'ni': '',
      'vehicle': on('vehicle') ? tachoWeek(sun)?.vehicle ?? '' : '',
      'signedDate': fmtShort(todayKey()),
      'weDate': fmtShort(addDays(sun, 6)),
      'page2': 'yes',
    };
  }

  String footVal(String sun, String k) {
    if (profileKeys.contains(k) && profile[k] != null) return profile[k].toString();
    final foot = weekState(sun)['foot'] as Map;
    if (foot.containsKey(k)) return (foot[k] ?? '').toString();
    return (autoFoot(sun)[k] ?? '').toString();
  }

  void setFootVal(String sun, String k, String v) {
    if (profileKeys.contains(k)) { profile[k] = v; } else {
      final w = weekState(sun);
      (w['foot'] as Map)[k] = v;
      w['editedAt'] = DateTime.now().millisecondsSinceEpoch;
    }
    changed();
  }

  // ---- suggestions: frequent stops, usual route, type-ahead ------------------------------
  List<({String type, String name, int c, double? lat, double? lon})> frequentStops() {
    final n = <String, ({String type, String name, int c, double? lat, double? lon})>{};
    final hidden = {...((profile['hiddenStops'] ?? const []) as List).cast<String>()};
    for (final e in diary.values) {
      for (final s in (e['stops'] ?? const []) as List) {
        final name = (s['name'] ?? '').toString().trim();
        if (name.length < 2) continue;
        final k = '${s['type']}|${name.toLowerCase()}';
        if (hidden.contains(k)) continue;
        final v = n[k];
        final ll = hasLL(Map<String, dynamic>.from(s as Map));
        n[k] = (type: (s['type'] ?? 'drop') as String, name: v?.name ?? name, c: (v?.c ?? 0) + 1,
            lat: ll ? numOf(s['lat']) : v?.lat, lon: ll ? numOf(s['lon']) : v?.lon);
      }
    }
    return (n.values.toList()..sort((a, b) => b.c.compareTo(a.c))).take(18).toList();
  }

  void renameStopEverywhere(String type, String oldName, String newType, String newName) {
    for (final e in diary.values) {
      for (final x in (e['stops'] ?? const []) as List) {
        if (x['type'] == type && (x['name'] ?? '').toString().trim().toLowerCase() == oldName.toLowerCase()) { x['name'] = newName; x['type'] = newType; }
      }
    }
    changed();
  }

  void hideStop(String type, String name) {
    profile['hiddenStops'] = {...((profile['hiddenStops'] ?? const []) as List).cast<String>(), '$type|${name.toLowerCase()}'}.toList();
    changed();
  }

  // How often each place followed `prev` in your diary (your usual route).
  Map<String, int> nextAfter(String? prev) {
    final m = <String, int>{}, p = (prev ?? '').trim().toLowerCase();
    if (p.isEmpty) { // nothing before it yet: the drop you usually do first
      for (final e in diary.values) {
        final l = (e['stops'] ?? const []) as List;
        final f = l.isEmpty ? '' : (l.first['name'] ?? '').toString().trim();
        if (f.isNotEmpty) m[f.toLowerCase()] = (m[f.toLowerCase()] ?? 0) + 1;
      }
      return m;
    }
    for (final e in diary.values) {
      final l = [e['start'], ...((e['stops'] ?? const []) as List).map((x) => x['name'])].map((x) => (x ?? '').toString().trim()).where((x) => x.isNotEmpty).toList();
      for (var i = 0; i + 1 < l.length; i++) { if (l[i].toLowerCase() == p) m[l[i + 1].toLowerCase()] = (m[l[i + 1].toLowerCase()] ?? 0) + 1; }
    }
    return m;
  }

  List<Suggestion> placeSuggestions(String q0, {String? prev}) {
    final q = q0.trim().toLowerCase();
    final nx = nextAfter(prev);
    int score(String name) {
      final n = name.toLowerCase();
      if (q.isEmpty) return 1;
      if (n.startsWith(q)) return 3;
      if (n.split(RegExp(r"[\s,()'’./-]+")).any((w) => w.startsWith(q))) return 2;
      return n.contains(q) ? 1 : 0;
    }
    final cand = <Suggestion>[];
    for (final s in stars) {
      cand.add(Suggestion(s['name'] ?? '', (s['note'] ?? '').toString().isNotEmpty ? s['note'] : 'Starred place', '⭐', lat: numOf(s['lat']), lon: numOf(s['lon']), w: 3,
          d: lastPos == null ? null : geo.distM(lastPos!.lat, lastPos!.lon, numOf(s['lat']), numOf(s['lon']))));
    }
    for (final p in places) { if ((p['name'] ?? '').toString().isNotEmpty) cand.add(Suggestion(p['name'], p['base'] == true ? 'Base' : 'Saved place', '📌', w: 2)); }
    for (final s in frequentStops()) {
      cand.add(Suggestion(s.name, 'Used ${s.c}×${s.type != 'drop' ? ' · ${stopTypes[s.type]}' : ''}', '🕘', w: 1, c: s.c, lat: s.lat, lon: s.lon));
    }
    for (final e in diary.values) { for (final n in [e['start'], e['finish']]) { if ((n ?? '').toString().isNotEmpty) cand.add(Suggestion(n, 'From your diary', '🕘', w: 1)); } }
    for (final p in knownPlaces) { cand.add(Suggestion(p['name'] as String, 'Known site', '🏭', lat: p['lat'] as double, lon: p['lon'] as double)); }
    // Skip what you're typing right now (the stop line saves as you type, so it is already "used once").
    bool typing(Suggestion c) => c.icon == '🕘' && c.c <= 1 && c.name.trim().toLowerCase() == q;
    final ranked = [
      for (final c in cand)
        if (score(c.name) > 0 && !typing(c))
          Suggestion(c.name, c.sub, c.icon, lat: c.lat, lon: c.lon, w: c.w, c: c.c, d: c.d, sc: score(c.name), nx: nx[c.name.toLowerCase()] ?? 0)
    ]..sort((a, b) {
        int cmp(num x, num y) => x.compareTo(y);
        var r = cmp(b.sc, a.sc); if (r != 0) return r;
        r = cmp(b.nx, a.nx); if (r != 0) return r;
        r = cmp(b.w, a.w); if (r != 0) return r;
        r = cmp(a.d ?? 1e9, b.d ?? 1e9); if (r != 0) return r;
        return cmp(b.c, a.c);
      });
    final seen = <String>{}, out = <Suggestion>[];
    for (final c in ranked) {
      if (!seen.add(c.name.toLowerCase())) continue;
      if (c.nx > 0) c.sub = 'Usually next (${c.nx}×) · ${c.sub}';
      out.add(c);
      if (out.length >= 8) break;
    }
    return out;
  }

  // ---- "Were you here?" --------------------------------------------------------------------
  List<({String name, double lat, double lon, double r, String icon})> herePlaces() => [
        for (final s in stars) (name: s['name'] as String? ?? '', lat: numOf(s['lat']), lon: numOf(s['lon']), r: numOf(s['radius']).isFinite ? numOf(s['radius']) : 250.0, icon: '⭐'),
        for (final p in places)
          if ((p['name'] ?? '').toString().isNotEmpty && p['base'] != true)
            (name: p['name'] as String, lat: numOf(p['lat']), lon: numOf(p['lon']), r: math.min(numOf(p['radius']).isFinite ? numOf(p['radius']) : 500.0, 1500.0), icon: '📌'),
      ];

  ({String name, double lat, double lon, double r, String icon})? placeAt(double lat, double lon, [double acc = 0]) {
    ({String name, double lat, double lon, double r, String icon})? best; var bd = double.infinity;
    for (final p in herePlaces()) {
      final d = geo.distM(lat, lon, p.lat, p.lon);
      if (d <= p.r + math.min(acc, 100) && d < bd) { best = p; bd = d; }
    }
    return best;
  }

  void logVisit(String name, double lat, double lon, int t) {
    final d = localKey(t), list = visits.putIfAbsent(d, () => []);
    if (list.any((v) => v['name'] == name)) return;
    list.add({'name': name, 'lat': lat, 'lon': lon, 't': t});
    final cut = addDays(todayKey(), -120);
    visits.removeWhere((k, _) => k.compareTo(cut) < 0);
    changed();
  }

  bool inDay(String date, String name) {
    final e = dget(date);
    return [e['start'], e['finish'], ...((e['stops'] ?? const []) as List).map((x) => x['name'])].any((n) => (n ?? '').toString().trim().toLowerCase() == name.toLowerCase());
  }
  bool dismissed(String date, String name) => (((profile['nearDismiss'] ?? const {}) as Map)[date] as List? ?? const []).contains(name);
  void dismiss(String date, String name) {
    final nd = Map<String, dynamic>.from((profile['nearDismiss'] ?? {}) as Map);
    nd[date] = [...((nd[date] ?? const []) as List), name];
    nd.removeWhere((k, _) => k.compareTo(addDays(todayKey(), -60)) < 0);
    profile['nearDismiss'] = nd;
    changed();
  }

  void addStopTo(String date, J st) {
    final l = stopsOn(date).where((x) => '${x['name'] ?? ''}${x['ref'] ?? ''}'.trim().isNotEmpty).toList()..add(st);
    setStops(date, l);
  }

  /// Places for a day: phone visits first, then tacho GPS positions that fall inside a place.
  List<NearVisit> nearbyFor(String date) {
    final out = <String, NearVisit>{};
    for (final v in visits[date] ?? const <J>[]) {
      out[(v['name'] as String).toLowerCase()] = NearVisit(v['name'], numOf(v['lat']), numOf(v['lon']), 'phone', local((v['t'] as num).toInt()).time);
    }
    if (prep != null && profile['nearTacho'] != 'no') {
      for (final f in prep!.fixes) {
        if (localKey(f.t!) != date) continue;
        final p = placeAt(f.pos.lat, f.pos.lon);
        if (p != null && !out.containsKey(p.name.toLowerCase())) out[p.name.toLowerCase()] = NearVisit(p.name, p.lat, p.lon, 'tacho', local(f.t!).time);
      }
    }
    return out.values.where((v) => !inDay(date, v.name) && !dismissed(date, v.name)).toList()..sort((a, b) => a.time.compareTo(b.time));
  }

  // ---- expenses ------------------------------------------------------------------------------
  List<J> expensesOn(String date) => [for (final e in weekState(sundayOfKey(date))['expenses'] as List) if ((e['day'] as num).toInt() == dayIdx(date)) e as J];
  double dayExpTotal(String date) {
    final w = weeks[sundayOfKey(date)];
    if (w == null) return 0;
    return (w['expenses'] as List).where((e) => (e['day'] as num).toInt() == dayIdx(date)).fold(0.0, (a, e) => a + money(e['amount']));
  }
  J addExpense(String date, String type) {
    final w = weekState(sundayOfKey(date));
    final e = <String, dynamic>{'id': uid(), 'day': dayIdx(date), 'type': type, 'note': '', 'amount': '', 'vat': ''};
    (w['expenses'] as List).add(e);
    changed();
    return e;
  }
  void removeExpense(String sun, J e) { (weekState(sun)['expenses'] as List).remove(e); _deleteAtt(e['att']); changed(); }

  /// Saves a receipt file into the app's folder and returns the attachment record.
  Future<J> saveAttachment(Uint8List bytes, String name, String mime) async {
    final id = uid(), ext = mime == 'application/pdf' ? 'pdf' : mime == 'image/png' ? 'png' : 'jpg';
    final f = File('${attDir.path}/$id.$ext');
    await f.writeAsBytes(bytes);
    return {'id': id, 'name': name, 'mime': mime, 'kind': mime == 'application/pdf' ? 'pdf' : 'image', 'file': '$id.$ext'};
  }
  File? attFile(dynamic att) => att is Map && att['file'] != null ? File('${attDir.path}/${att['file']}') : null;
  void _deleteAtt(dynamic att) { final f = attFile(att); if (f != null && f.existsSync()) f.deleteSync(); }
  void removeAttachment(J holder) { _deleteAtt(holder['att']); holder.remove('att'); changed(); }
  void removeOther(String sun, J a) { _deleteAtt(a); (weekState(sun)['other'] as List).remove(a); changed(); }

  // ---- downloaded? / email -----------------------------------------------------------------------
  String fileName(String sun) { final (y, m, d) = parts(sun); return 'TC_timesheet_${d}_${m}_${'$y'.substring(2)}.pdf'; }

  void markDone(String sun, String how) { weekState(sun)['done'] = {'at': DateTime.now().millisecondsSinceEpoch, 'how': how, 'file': fileName(sun)}; changed(); }

  static const defaultEmail = 'Hello,\n\nPlease find attached my timesheet for the week commencing {weekCommencing} (vehicle {vehicle}).\n\n'
      'Days worked: {days}. Nights out: {nights}. Expenses: £{expenses}.\n\nKind regards,\n{name}';
  static const defaultSubject = 'Weekly Timesheet - {cardName}({wc})';

  // "SMITH JOHN-PAUL" -> "Smith John-Paul"
  static String titleCase(String t) => t.toLowerCase().replaceAllMapped(RegExp(r"(^|[\s'’-])(\p{L})", unicode: true), (m) => '${m[1]}${m[2]!.toUpperCase()}');

  Map<String, String> emailVals(String sun, {required int nights, required double expenses}) {
    final id = card?.identification;
    final days = List.generate(7, (i) => i);
    final list = days.where((i) => dayVal(sun, i, 'startTime').isNotEmpty).map((i) {
      final sp = dayVal(sun, i, 'startPlace'), fp = dayVal(sun, i, 'finishPlace'), dr = dayVal(sun, i, 'drops');
      return '${dayNames[i].substring(0, 3)} ${fmtShort(addDays(sun, i))}: ${dayVal(sun, i, 'startTime')}-${dayVal(sun, i, 'finishTime')}'
          '${sp.isNotEmpty || fp.isNotEmpty ? ' ${sp.isEmpty ? '?' : sp} to ${fp.isEmpty ? '?' : fp}' : ''}${dr.isNotEmpty ? ' ($dr)' : ''}';
    }).join('\n');
    final name = footVal(sun, 'name');
    return {
      'name': name, 'firstName': id != null ? id.firstNames.split(' ').first : name.split(' ').last,
      'weekCommencing': fmtShort(sun), 'weekEnding': fmtShort(addDays(sun, 6)), 'vehicle': footVal(sun, 'vehicle'),
      'days': '${days.where((i) => dayVal(sun, i, 'startTime').isNotEmpty || dayVal(sun, i, 'finishTime').isNotEmpty).length}',
      'nights': '$nights', 'expenses': expenses.toStringAsFixed(2), 'daysList': list, 'file': fileName(sun),
      'cardName': titleCase(id != null ? '${id.surname} ${id.firstNames}' : name),
      'wc': fmtShort(sun).substring(0, 5), 'we': fmtShort(addDays(sun, 6)).substring(0, 5),
    };
  }

  static String fillTpl(String tpl, Map<String, String> vals) => tpl.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => vals[m[1]] ?? m[0]!);

  // ---- signature -------------------------------------------------------------------------------------
  Uint8List? get signatureBytes {
    final s = profile['signature'];
    if (s is! String || !s.startsWith('data:')) return null;
    return base64Decode(s.substring(s.indexOf(',') + 1));
  }
  set signatureBytes(Uint8List? png) {
    if (png == null) { profile.remove('signature'); } else { profile['signature'] = 'data:image/png;base64,${base64Encode(png)}'; }
    changed();
  }
}
