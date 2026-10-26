// Location helpers: what's around me, reading Google Maps links, navigation links,
// and GPX / KML / CSV import-export for starred places. Port of places.js.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

const _ua = {'User-Agent': 'Tuki/2.0 (io.github.yessirks.tuki)'};

double distM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0, rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

String fmtDist(double m) {
  if (m < 1000) { final r = (m / 5).round() * 5; return '${r == 0 ? 5 : r} m'; }
  return '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';
}

bool okCoords(double lat, double lon) => lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180 && !(lat == 0 && lon == 0);

Future<http.Response> _get(String url, [int ms = 10000]) => http.get(Uri.parse(url), headers: _ua).timeout(Duration(milliseconds: ms));

class Reverse { final String town, postcode, road, name, display; Reverse(this.town, this.postcode, this.road, this.name, this.display); }

Future<Reverse> reverse(double lat, double lon) async {
  final r = await _get('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat.toStringAsFixed(6)}&lon=${lon.toStringAsFixed(6)}&zoom=18&addressdetails=1&accept-language=en');
  if (r.statusCode != 200) throw Exception('lookup failed');
  final j = jsonDecode(r.body) as Map<String, dynamic>, a = (j['address'] ?? {}) as Map<String, dynamic>;
  String s(String k) => (a[k] ?? '') as String;
  final town = [s('town'), s('village'), s('city'), s('suburb'), s('hamlet'), s('county')].firstWhere((x) => x.isNotEmpty, orElse: () => '');
  return Reverse(town, s('postcode'), s('road'), (j['name'] ?? '') as String, (j['display_name'] ?? '') as String);
}

/// Reverse geocode for timesheet labels: a POI name only for things a lorry stops at, otherwise the town.
class GeoLabel {
  final String label, town, postcode, cc, display;
  GeoLabel(this.label, this.town, this.postcode, this.cc, this.display);
  Map<String, dynamic> toJson() => {'label': label, 'town': town, 'postcode': postcode, 'cc': cc, 'display': display};
  factory GeoLabel.fromJson(Map<String, dynamic> j) =>
      GeoLabel(j['label'] ?? '', j['town'] ?? '', j['postcode'] ?? '', j['cc'] ?? '', j['display'] ?? '');
}

Future<GeoLabel> labelFor(double lat, double lon) async {
  final r = await _get('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat.toStringAsFixed(5)}&lon=${lon.toStringAsFixed(5)}&zoom=18&addressdetails=1&accept-language=en');
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final j = jsonDecode(r.body) as Map<String, dynamic>, a = (j['address'] ?? {}) as Map<String, dynamic>;
  String s(String k) => (a[k] ?? '') as String;
  final town = [s('village'), s('town'), s('city'), s('hamlet'), s('suburb'), s('municipality'), s('county')].firstWhere((x) => x.isNotEmpty, orElse: () => '');
  final c = j['category'], t = j['type'];
  final poi = (c == 'highway' && (t == 'services' || t == 'rest_area')) || (c == 'amenity' && (t == 'fuel' || t == 'truck_stop')) ||
      ['industrial', 'man_made', 'office', 'craft'].contains(c) || (c == 'landuse' && t == 'industrial') ||
      (c == 'shop' && ['supermarket', 'wholesale', 'doityourself', 'department_store'].contains(t)) ||
      (c == 'building' && ['warehouse', 'industrial', 'commercial', 'retail'].contains(t));
  final name = (j['name'] ?? '') as String;
  return GeoLabel(poi && name.isNotEmpty ? name : town, town, s('postcode'), s('country_code').toUpperCase(), (j['display_name'] ?? '') as String);
}

class NearPlace { final String name, kind, city; final double lat, lon; double dist; NearPlace(this.name, this.kind, this.lat, this.lon, this.city, [this.dist = 0]); }

const _skip = ['parking', 'parking_entrance', 'bench', 'waste_basket', 'toilets', 'telephone', 'post_box', 'bicycle_parking', 'place_of_worship', 'house', 'residential', 'yes', 'grave_yard'];
const _overpass = ['https://overpass-api.de/api/interpreter', 'https://overpass.private.coffee/api/interpreter', 'https://maps.mail.ru/osm/tools/overpass/api/interpreter'];

// Photon (komoot): fast, and returns the town with each place.
Future<List<NearPlace>> _photon(double lat, double lon, int radius) async {
  final tags = ['shop', 'amenity', 'landuse:industrial', 'landuse:commercial', 'landuse:retail', 'landuse:farmyard', 'industrial', 'building', 'man_made', 'office', 'craft', 'highway:services', 'highway:rest_area']
      .map((t) => '&osm_tag=${Uri.encodeComponent(t)}').join();
  final r = await _get('https://photon.komoot.io/reverse?lat=$lat&lon=$lon&limit=30&radius=${radius / 1000}&lang=en$tags');
  if (r.statusCode != 200) throw Exception('photon ${r.statusCode}');
  final feats = (jsonDecode(r.body)['features'] ?? []) as List;
  return [for (final f in feats) _photonPlace(f)];
}
NearPlace _photonPlace(dynamic f) {
  final p = (f['properties'] ?? {}) as Map, c = f['geometry']['coordinates'] as List;
  String s(String k) => (p[k] ?? '').toString();
  final city = [s('city'), s('town'), s('village'), s('district')].firstWhere((x) => x.isNotEmpty, orElse: () => '');
  return NearPlace(s('name'), s('osm_value'), (c[1] as num).toDouble(), (c[0] as num).toDouble(), city);
}

// Overpass: the full map database; often busy, so it's the backup.
Future<List<NearPlace>> _overpassNear(double lat, double lon, int radius) async {
  final q = '[out:json][timeout:12];('
      'nwr(around:$radius,$lat,$lon)[name][~"^(shop|amenity|industrial|office|craft|man_made|building|tourism|company)\$"~"."];'
      'nwr(around:$radius,$lat,$lon)[name]["landuse"~"industrial|commercial|retail|farmyard"];'
      'nwr(around:$radius,$lat,$lon)[name]["highway"~"services|rest_area"];'
      ');out center tags 60;';
  for (final url in _overpass) {
    try {
      final r = await http.post(Uri.parse(url), headers: {..._ua, 'Content-Type': 'application/x-www-form-urlencoded'}, body: 'data=${Uri.encodeComponent(q)}')
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) continue;
      final els = (jsonDecode(r.body)['elements'] ?? []) as List;
      return [
        for (final el in els)
          () {
            final t = (el['tags'] ?? {}) as Map, p = el['center'] ?? el;
            String s(String k) => (t[k] ?? '').toString();
            final name = s('brand').isNotEmpty && s('name').isNotEmpty && !s('name').toLowerCase().contains(s('brand').toLowerCase()) ? '${s('brand')} ${s('name')}' : s('name');
            final kind = ['shop', 'amenity', 'industrial', 'office', 'craft', 'man_made', 'landuse', 'highway', 'tourism', 'building'].map(s).firstWhere((x) => x.isNotEmpty, orElse: () => '');
            final city = s('addr:city').isNotEmpty ? s('addr:city') : s('addr:town');
            return NearPlace(name, kind, (p['lat'] as num).toDouble(), (p['lon'] as num).toDouble(), city);
          }()
      ];
    } catch (_) { /* next mirror */ }
  }
  throw Exception('The map server is busy.');
}

final _trade = RegExp(r'supermarket|wholesale|warehouse|industrial|depot|factory|works|distribution|logistics|farm|dairy|services|fuel|cash.and.carry|doityourself|trade|retail|commercial|hardware|garden.centre|department.store|car.parts|builders', caseSensitive: false);

/// Named places a lorry stops at, ranked: supermarkets, depots, factories and services first.
Future<List<NearPlace>> nearby(double lat, double lon, {int radius = 300}) async {
  List<NearPlace> raw;
  try { raw = await _photon(lat, lon, radius); } catch (_) { raw = await _overpassNear(lat, lon, radius); }
  final seen = <String>{}, out = <NearPlace>[];
  for (final p in raw) {
    if (p.name.isEmpty || !okCoords(p.lat, p.lon) || _skip.contains(p.kind)) continue;
    if (!seen.add(p.name.toLowerCase())) continue;
    out.add(NearPlace(p.name, p.kind.replaceAll('_', ' '), p.lat, p.lon, p.city, distM(lat, lon, p.lat, p.lon)));
  }
  double rank(NearPlace p) => p.dist * (_trade.hasMatch(p.kind) ? 0.5 : 1);
  out.sort((a, b) => rank(a).compareTo(rank(b)));
  return out.take(15).toList();
}

class SearchHit { final String name, city, sub; final double lat, lon; SearchHit(this.name, this.city, this.sub, this.lat, this.lon); }

/// Search a name, address or postcode (UK), nearest to you first when we know where you are.
Future<List<SearchHit>> search(String q, {double? nearLat, double? nearLon}) async {
  final bias = nearLat != null ? '&lat=$nearLat&lon=$nearLon' : '';
  try {
    final r = await _get('https://photon.komoot.io/api/?q=${Uri.encodeComponent(q)}&limit=8&lang=en&bbox=-8.7,49.8,2.0,60.9$bias', 8000);
    if (r.statusCode == 200) {
      final feats = (jsonDecode(r.body)['features'] ?? []) as List;
      final seen = <String>{}, out = <SearchHit>[];
      for (final f in feats) {
        final p = (f['properties'] ?? {}) as Map, c = f['geometry']['coordinates'] as List;
        String s(String k) => (p[k] ?? '').toString();
        final city = [s('city'), s('town'), s('village')].firstWhere((x) => x.isNotEmpty, orElse: () => '');
        final street = [s('housenumber'), s('street')].where((x) => x.isNotEmpty).join(' ');
        final name = s('name').isNotEmpty ? s('name') : street.isNotEmpty ? street : s('postcode');
        if (name.isEmpty) continue;
        final sub = [s('street'), city, s('postcode')].where((x) => x.isNotEmpty).join(', ');
        if (!seen.add('$name|$sub'.toLowerCase())) continue;
        out.add(SearchHit(name, city, sub, (c[1] as num).toDouble(), (c[0] as num).toDouble()));
      }
      if (out.isNotEmpty) return out;
    }
  } catch (_) { /* try Nominatim */ }
  final r = await _get('https://nominatim.openstreetmap.org/search?format=jsonv2&q=${Uri.encodeComponent(q)}&countrycodes=gb&limit=8', 8000);
  if (r.statusCode != 200) throw Exception('search failed');
  return [
    for (final x in jsonDecode(r.body) as List)
      () {
        final parts = (x['display_name'] as String).split(',');
        return SearchHit((x['name'] ?? '').toString().isNotEmpty ? x['name'] : parts.first, '', parts.skip(1).take(3).join(',').trim(),
            double.parse(x['lat'].toString()), double.parse(x['lon'].toString()));
      }()
  ];
}

// ---- reading coordinates out of whatever you paste ------------------------------------
class Coords { final double lat, lon; final String name; Coords(this.lat, this.lon, [this.name = '']); }

final _dmsAll = RegExp(r'''(\d+(?:\.\d+)?)\s*°\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*)?(?:(\d+(?:\.\d+)?)\s*["″]\s*)?([NSEW])''', caseSensitive: false);
Coords? _dms(String s) {
  final m = _dmsAll.allMatches(s).toList();
  if (m.length < 2) return null;
  (double, bool) one(RegExpMatch p) {
    final v = double.parse(p[1]!) + (double.tryParse(p[2] ?? '') ?? 0) / 60 + (double.tryParse(p[3] ?? '') ?? 0) / 3600;
    final h = p[4]!.toUpperCase();
    return (h == 'S' || h == 'W' ? -v : v, h == 'N' || h == 'S');
  }
  final a = one(m[0]), b = one(m[1]);
  final lat = a.$2 ? a.$1 : b.$1, lon = a.$2 ? b.$1 : a.$1;
  return okCoords(lat, lon) ? Coords(lat, lon) : null;
}

final _coordPats = [
  RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)'), // the pin itself in a Google place link
  RegExp(r'[?&](?:q|query|ll|destination|daddr|sll|center)=(-?\d+(?:\.\d+)?)(?:,|%2C)\s*(-?\d+(?:\.\d+)?)', caseSensitive: false),
  RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)'), // map centre
  RegExp(r'geo:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)', caseSensitive: false),
  RegExp(r'[?&]mlat=(-?\d+(?:\.\d+)?)&mlon=(-?\d+(?:\.\d+)?)'),
  RegExp(r'^\s*(-?\d{1,2}\.\d+)\s*[,;\s]\s*(-?\d{1,3}\.\d+)\s*$'), // "50.4434, -4.6394"
  RegExp(r'(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})'),
];

/// Google Maps links (long ones), "lat, lon", geo: URIs, Apple/Waze/OSM links, degrees-minutes-seconds.
Coords? parseCoords(String? text) {
  if (text == null) return null;
  final s = text.trim();
  var name = '';
  final pm = RegExp(r'/place/([^/@?]+)').firstMatch(s);
  if (pm != null) { try { name = Uri.decodeComponent(pm[1]!.replaceAll('+', ' ')); } catch (_) {} }
  for (final p in _coordPats) {
    final m = p.firstMatch(s);
    if (m != null) {
      final lat = double.parse(m[1]!), lon = double.parse(m[2]!);
      if (okCoords(lat, lon)) return Coords(lat, lon, name);
    }
  }
  final d = _dms(s);
  return d != null ? Coords(d.lat, d.lon, name) : null;
}

bool isShortLink(String? s) => RegExp(r'(maps\.app\.goo\.gl|goo\.gl/maps|g\.co/kgs)', caseSensitive: false).hasMatch(s ?? '');

// ---- navigation ---------------------------------------------------------------------
String llText(double lat, double lon) => '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
Uri googleNav(double lat, double lon) => Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${llText(lat, lon)}&travelmode=driving');
Uri wazeNav(double lat, double lon) => Uri.parse('https://waze.com/ul?ll=${llText(lat, lon)}&navigate=yes');
// On Android the geo: link lets you pick TomTom (or any sat-nav app).
Uri geoNav(double lat, double lon, String name) => Uri.parse('geo:${llText(lat, lon)}?q=${llText(lat, lon)}(${Uri.encodeComponent(name.isEmpty ? 'Destination' : name)})');
Uri googleView(double lat, double lon) => Uri.parse('https://www.google.com/maps/search/?api=1&query=${llText(lat, lon)}');

// ---- export / import ------------------------------------------------------------------
class PlaceIO { final String name, note; final double lat, lon; PlaceIO(this.name, this.lat, this.lon, [this.note = '']); }

String _x(String s) => s.replaceAllMapped(RegExp('[<>&\'"]'), (m) => const {'<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;'}[m[0]]!);

String toGPX(List<PlaceIO> list) => '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Tuki" xmlns="http://www.topografix.com/GPX/1/1">\n'
    '${list.map((p) => '  <wpt lat="${p.lat.toStringAsFixed(6)}" lon="${p.lon.toStringAsFixed(6)}"><name>${_x(p.name)}</name>${p.note.isNotEmpty ? '<desc>${_x(p.note)}</desc>' : ''}</wpt>').join('\n')}\n</gpx>\n';

String toKML(List<PlaceIO> list) => '<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Starred places</name>\n'
    '${list.map((p) => '<Placemark><name>${_x(p.name)}</name>${p.note.isNotEmpty ? '<description>${_x(p.note)}</description>' : ''}<Point><coordinates>${p.lon.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)},0</coordinates></Point></Placemark>').join('\n')}'
    '\n</Document></kml>\n';

String toCSV(List<PlaceIO> list) {
  String q(String s) => '"${s.replaceAll('"', '""')}"';
  return 'name,latitude,longitude,note\n${list.map((p) => [q(p.name), p.lat.toStringAsFixed(6), p.lon.toStringAsFixed(6), q(p.note)].join(',')).join('\n')}\n';
}

List<PlaceIO> parseImport(String text) {
  final out = <PlaceIO>[];
  if (RegExp(r'<gpx|<kml', caseSensitive: false).hasMatch(text)) {
    final doc = XmlDocument.parse(text);
    String child(XmlElement e, String n) => e.findElements(n).isEmpty ? '' : e.findElements(n).first.innerText;
    for (final w in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'wpt' || e.name.local == 'rtept')) {
      final lat = double.tryParse(w.getAttribute('lat') ?? '') ?? double.nan, lon = double.tryParse(w.getAttribute('lon') ?? '') ?? double.nan;
      final name = child(w, 'name');
      if (okCoords(lat, lon)) out.add(PlaceIO(name.isEmpty ? 'Imported place' : name, lat, lon, child(w, 'desc')));
    }
    for (final pm in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'Placemark')) {
      final c = pm.descendants.whereType<XmlElement>().where((e) => e.name.local == 'coordinates').map((e) => e.innerText).firstOrNull;
      if (c == null) continue;
      final parts = c.trim().split(',').map((x) => double.tryParse(x.trim()) ?? double.nan).toList();
      if (parts.length < 2) continue;
      final name = child(pm, 'name');
      if (okCoords(parts[1], parts[0])) out.add(PlaceIO(name.isEmpty ? 'Imported place' : name, parts[1], parts[0], child(pm, 'description')));
    }
    return out;
  }
  // CSV, or one place per line: "name, lat, lon" / a Google link / "lat, lon"
  final cellRe = RegExp(r'("([^"]|"")*"|[^,]*)(,|$)');
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty || RegExp(r'^name\s*,', caseSensitive: false).hasMatch(line)) continue;
    final cells = cellRe.allMatches(line).map((m) => m[0]!).where((c) => c.isNotEmpty)
        .map((c) => c.replaceFirst(RegExp(r',$'), '').replaceAll(RegExp(r'^"|"$'), '').replaceAll('""', '"').trim()).toList();
    if (cells.length >= 3) {
      final lat = double.tryParse(cells[1]), lon = double.tryParse(cells[2]);
      if (lat != null && lon != null && okCoords(lat, lon)) { out.add(PlaceIO(cells[0].isEmpty ? 'Imported place' : cells[0], lat, lon, cells.length > 3 ? cells[3] : '')); continue; }
    }
    final p = parseCoords(line);
    if (p != null) {
      final rest = line.replaceAll(RegExp(r'https?:\S+'), '').replaceFirst(RegExp(r'-?\d+\.\d+\s*,\s*-?\d+\.\d+'), '').trim();
      out.add(PlaceIO(p.name.isNotEmpty ? p.name : rest.isNotEmpty ? rest : 'Imported place', p.lat, p.lon));
    }
  }
  return out;
}
