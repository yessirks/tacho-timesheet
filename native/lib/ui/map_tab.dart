// Map tab: starred spots (gate entrances) you can navigate to, your drops on the map, saved areas.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/geo.dart' as geo;
import '../core/week.dart' show dayIdx;
import '../data/store.dart';
import 'common.dart';

// ---- base maps -------------------------------------------------------------------------
const mapStyles = ['Map', 'Clean', 'Satellite + roads', 'Satellite'];
const _ua = 'io.github.yessirks.tuki';
List<Widget> tilesFor(String style) {
  TileLayer esri(String p) => TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/$p/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: _ua, maxZoom: 19);
  switch (style) {
    case 'Clean': return [esri('World_Street_Map')];
    case 'Satellite + roads': return [esri('World_Imagery'), esri('Reference/World_Transportation'), esri('Reference/World_Boundaries_and_Places')];
    case 'Satellite': return [esri('World_Imagery')];
    default: return [TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: _ua, maxZoom: 19)];
  }
}
String attributionFor(String style) => style == 'Map' ? '© OpenStreetMap contributors' : style == 'Clean' ? 'Map © Esri' : 'Imagery © Esri';

Future<void> openUri(BuildContext context, Uri u) async {
  if (!await launchUrl(u, mode: LaunchMode.externalApplication)) { if (context.mounted) toast(context, 'No app could open that.'); }
}

/// Google Maps / Waze / other sat-nav / copy, for one place.
Widget navButtons(BuildContext context, double lat, double lon, String name) => Wrap(spacing: 8, runSpacing: 6, children: [
      FilledButton.icon(onPressed: () => openUri(context, geo.googleNav(lat, lon)), icon: const Icon(Icons.navigation, size: 18), label: const Text('Google Maps')),
      OutlinedButton(onPressed: () => openUri(context, geo.wazeNav(lat, lon)), child: const Text('Waze')),
      OutlinedButton(onPressed: () => openUri(context, geo.geoNav(lat, lon, name)), child: const Text('TomTom / other')),
      OutlinedButton(onPressed: () { Clipboard.setData(ClipboardData(text: geo.llText(lat, lon))); toast(context, 'Copied ${geo.llText(lat, lon)}'); }, child: const Text('Copy')),
    ]);

class MapTab extends StatefulWidget {
  final void Function(String date) openDay;
  const MapTab({super.key, required this.openDay});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final map = MapController();
  final sheetCtl = DraggableScrollableController();
  String q = '';
  bool fitted = false, showStars = true, showDrops = true, showAreas = true;
  String get style => (store.profile['mapStyle'] as String?) ?? 'Map';

  void _fit() {
    if (fitted) return;
    final pts = [...store.stars, ...store.places].where(hasLL).map((p) => LatLng(numOf(p['lat']), numOf(p['lon']))).toList();
    if (pts.isEmpty) return;
    fitted = true;
    if (pts.length == 1) { map.move(pts.first, 14); return; }
    map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.fromLTRB(40, 80, 40, 260), maxZoom: 14));
  }

  Future<void> _locate() async {
    try {
      final p = await getHere();
      map.move(LatLng(p.lat, p.lon), map.camera.zoom < 16 ? 16 : map.camera.zoom);
      setState(() {});
    } catch (e) { if (mounted) alert(context, '$e'); }
  }

  Future<void> _starHere() async {
    final p = await locatePicker(context, '⭐ Star where I am: what is this place?', offerStar: false);
    if (p == null || !mounted) return;
    if (p.lat == null) { alert(context, 'No location, so nothing was starred.'); return; }
    store.addStar({'name': p.name, 'lat': p.lat, 'lon': p.lon});
    toast(context, '⭐ Saved ${p.name}');
    final s = store.stars.where((x) => x['name'] == p.name && geo.distM(numOf(x['lat']), numOf(x['lon']), p.lat!, p.lon!) < 25).firstOrNull;
    if (s != null) await starEditor(context, s); // straight into the note: gate, bay, phone…
  }

  Future<void> _pick() async {
    final c = map.camera.center;
    final spot = await pinMap(context, LatLng(c.latitude, c.longitude), map.camera.zoom < 6 ? 6 : map.camera.zoom, 'Zoom in and put the pin on the gate');
    if (spot != null && mounted) await starEditor(context, {'lat': spot.latitude, 'lon': spot.longitude});
  }

  Future<void> _export(String kind) async {
    final list = [for (final s in store.stars) geo.PlaceIO(s['name'] ?? '', numOf(s['lat']), numOf(s['lon']), (s['note'] ?? '') as String)];
    final txt = kind == 'gpx' ? geo.toGPX(list) : kind == 'kml' ? geo.toKML(list) : geo.toCSV(list);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/starred-places-${DateTime.now().toIso8601String().substring(0, 10)}.$kind');
    await f.writeAsString(txt);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'Starred places'));
  }

  Future<void> _import() async {
    final f = await pickOne();
    if (f == null || !mounted) return;
    final list = geo.parseImport(utf8.decode(f.bytes, allowMalformed: true));
    if (list.isEmpty) { alert(context, 'No places found in that file.'); return; }
    for (final p in list) { store.addStar({'name': p.name, 'lat': p.lat, 'lon': p.lon, 'note': p.note}, save: false); }
    store.changed();
    toast(context, '⭐ Imported ${list.length} places');
  }

  Future<void> _bulk() async {
    final ctl = TextEditingController();
    final list = await sheet<List<geo.PlaceIO>>(context, (c) => StatefulBuilder(builder: (c, set) {
          final found = geo.parseImport(ctl.text);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Paste several places', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('One place per line, like "Sainsbury\'s Paignton gate, 50.4362, -3.5699", or Google Maps links with coordinates in them.', style: TextStyle(color: mutedColor(c))),
            const SizedBox(height: 10),
            TextField(controller: ctl, maxLines: 6, onChanged: (_) => set(() {}), decoration: const InputDecoration(hintText: '50.4362, -3.5699\nhttps://www.google.com/maps/place/…')),
            const SizedBox(height: 6),
            Text(geo.isShortLink(ctl.text) && found.isEmpty ? 'Short "maps.app.goo.gl" links can\'t be read. Copy the coordinates instead (press and hold the spot in Google Maps).'
                : found.isNotEmpty ? 'Found ${found.length} place${found.length > 1 ? 's' : ''}.' : '', style: TextStyle(color: mutedColor(c))),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: found.isEmpty ? null : () => Navigator.pop(c, found), child: const Text('Next'))),
          ]);
        }));
    if (list == null || !mounted) return;
    if (list.length == 1) {
      final p = list.first;
      await starEditor(context, {'name': p.name == 'Imported place' ? '' : p.name, 'note': p.note, 'lat': p.lat, 'lon': p.lon});
      return;
    }
    for (final p in list) { store.addStar({'name': p.name, 'lat': p.lat, 'lon': p.lon, 'note': p.note}, save: false); }
    store.changed();
    toast(context, '⭐ Added ${list.length} places');
  }

  void _dropSheet(String date, J st) => sheet(context, (c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${stopTypes[st['type']] ?? 'Stop'} · ${st['name'] ?? ''}${(st['ref'] ?? '').toString().isNotEmpty ? ' (${st['ref']})' : ''}',
            style: Theme.of(c).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        Text('${dayNames[dayIdx(date)]} ${fmtDay(date)} ${date.substring(0, 4)}', style: TextStyle(color: mutedColor(c))),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.tonal(onPressed: () { Navigator.pop(c); starEditor(context, {'name': st['name'] ?? '', 'lat': st['lat'], 'lon': st['lon']}); }, child: const Text('⭐ Star this spot')),
          OutlinedButton(onPressed: () { Navigator.pop(c); widget.openDay(date); }, child: const Text('Open day')),
        ]),
      ]));

  void _starSheet(J s) => sheet(context, (c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('⭐ ${s['name']}', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        if ((s['note'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(s['note'])),
        Text('${numOf(s['lat']).toStringAsFixed(5)}, ${numOf(s['lon']).toStringAsFixed(5)}', style: TextStyle(color: mutedColor(c))),
        const SizedBox(height: 12),
        navButtons(c, numOf(s['lat']), numOf(s['lon']), s['name'] ?? ''),
        const SizedBox(height: 8),
        TextButton.icon(onPressed: () { Navigator.pop(c); starEditor(context, s); }, icon: const Icon(Icons.edit, size: 18), label: const Text('Edit')),
      ]));

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: store, builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final me = store.lastPos;
        final starList = store.stars.where((s) => q.isEmpty || '${s['name']} ${s['note']}'.toLowerCase().contains(q.toLowerCase()))
            .map((s) => (s: s, d: me == null ? null : geo.distM(me.lat, me.lon, numOf(s['lat']), numOf(s['lon'])))).toList()
          ..sort((a, b) => a.d != null && b.d != null ? a.d!.compareTo(b.d!) : '${a.s['name']}'.compareTo('${b.s['name']}'));
        return Stack(children: [
          FlutterMap(
            mapController: map,
            options: MapOptions(initialCenter: const LatLng(52.4, -2.5), initialZoom: 6, onMapReady: _fit,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate)),
            children: [
              ...tilesFor(style),
              if (showAreas)
                CircleLayer(circles: [
                  for (final p in store.places)
                    if (hasLL(p))
                      CircleMarker(point: LatLng(numOf(p['lat']), numOf(p['lon'])), radius: numOf(p['radius']).isFinite ? numOf(p['radius']) : 500, useRadiusInMeter: true,
                          color: (p['base'] == true ? Colors.green : Colors.blue).withValues(alpha: .10), borderColor: p['base'] == true ? const Color(0xFF1D7A46) : const Color(0xFF1F4FBF), borderStrokeWidth: 1.5),
                ]),
              if (showDrops)
                MarkerLayer(markers: [
                  for (final e in store.diary.entries)
                    for (final st in (e.value['stops'] ?? const []) as List)
                      if (hasLL(Map<String, dynamic>.from(st as Map)))
                        Marker(point: LatLng(numOf(st['lat']), numOf(st['lon'])), width: 18, height: 18,
                            child: GestureDetector(onTap: () => _dropSheet(e.key, Map<String, dynamic>.from(st)),
                                child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: st['type'] == 'drop' ? const Color(0xFFE8890C) : const Color(0xFF7C3AED),
                                    border: Border.all(color: Colors.white, width: 2))))),
                ]),
              if (showStars)
                MarkerLayer(markers: [
                  for (final s in store.stars)
                    if (hasLL(s))
                      // The box is centred on the spot and the pin fills its top half, so the tip is on the coordinate.
                      Marker(point: LatLng(numOf(s['lat']), numOf(s['lon'])), width: 150, height: 80, alignment: Alignment.center,
                          child: Align(alignment: Alignment.topCenter, child: GestureDetector(onTap: () => _starSheet(s), child: StarPin(name: s['name'] ?? '')))),
                ]),
              if (me != null) ...[
                CircleLayer(circles: [CircleMarker(point: LatLng(me.lat, me.lon), radius: me.acc, useRadiusInMeter: true, color: Colors.blue.withValues(alpha: .1), borderColor: Colors.blue, borderStrokeWidth: 1)]),
                MarkerLayer(markers: [Marker(point: LatLng(me.lat, me.lon), width: 20, height: 20,
                    child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF1F4FBF), border: Border.all(color: Colors.white, width: 3))))]),
              ],
              RichAttributionWidget(alignment: AttributionAlignment.bottomLeft, attributions: [TextSourceAttribution(attributionFor(style))]),
            ],
          ),
          // top bar: search a place to add, map layers
          SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(children: [
              Expanded(child: Material(
                elevation: 3, borderRadius: BorderRadius.circular(28), color: cs.surface,
                child: InkWell(borderRadius: BorderRadius.circular(28), onTap: () => addPlaceFlow(context, near: store.lastPos),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13), child: Row(children: [
                      const TukiMark(size: 26), const SizedBox(width: 10),
                      Expanded(child: Text('Search or paste a place to star', style: TextStyle(color: mutedColor(context)))),
                      const Icon(Icons.search),
                    ]))),
              )),
              const SizedBox(width: 8),
              Material(elevation: 3, shape: const CircleBorder(), color: cs.surface, child: PopupMenuButton<String>(
                icon: const Icon(Icons.layers_outlined), tooltip: 'Map style',
                onSelected: (v) {
                  if (mapStyles.contains(v)) { store.profile['mapStyle'] = v; store.changed(); return; }
                  setState(() { if (v == 'stars') showStars = !showStars; if (v == 'drops') showDrops = !showDrops; if (v == 'areas') showAreas = !showAreas; });
                },
                itemBuilder: (_) => [
                  for (final m in mapStyles) CheckedPopupMenuItem(value: m, checked: style == m, child: Text(m)),
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(value: 'stars', checked: showStars, child: const Text('⭐ Starred')),
                  CheckedPopupMenuItem(value: 'drops', checked: showDrops, child: const Text('🚚 My drops')),
                  CheckedPopupMenuItem(value: 'areas', checked: showAreas, child: const Text('◯ Saved areas')),
                ],
              )),
            ]),
          )),
          Positioned(right: 14, bottom: 210, child: FloatingActionButton.small(heroTag: 'loc', onPressed: _locate, tooltip: 'Where am I?', child: const Icon(Icons.my_location))),
          // starred places sheet
          DraggableScrollableSheet(
            controller: sheetCtl, initialChildSize: .26, minChildSize: .12, maxChildSize: .9, snap: true, snapSizes: const [.26, .55],
            builder: (context, sc) => Material(
              elevation: 8, color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(14, 8, 14, 20), children: [
                Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 10),
                Row(children: [
                  Text('Starred places', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  if (store.stars.isNotEmpty) Text('  ${store.stars.length}', style: TextStyle(color: mutedColor(context))),
                  const Spacer(),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (v) => v == 'import' ? _import() : v == 'bulk' ? _bulk() : _export(v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'bulk', child: Text('Paste several places')),
                      PopupMenuItem(value: 'import', child: Text('Import GPX / KML / CSV')),
                      PopupMenuDivider(),
                      PopupMenuItem(value: 'gpx', child: Text('Export GPX (sat-navs)')),
                      PopupMenuItem(value: 'kml', child: Text('Export KML (Google Earth)')),
                      PopupMenuItem(value: 'csv', child: Text('Export CSV (spreadsheet)')),
                    ],
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: FilledButton.icon(onPressed: _starHere, icon: const Icon(Icons.star, size: 18), label: const Text('Star here'))),
                  const SizedBox(width: 8),
                  Expanded(child: FilledButton.tonalIcon(onPressed: _pick, icon: const Icon(Icons.satellite_alt, size: 18), label: const Text('Pick on map'))),
                ]),
                const SizedBox(height: 10),
                TextField(onChanged: (v) => setState(() => q = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search starred places')),
                const SizedBox(height: 6),
                if (starList.isEmpty)
                  Padding(padding: const EdgeInsets.all(12), child: Text(store.stars.isEmpty
                      ? 'No starred places yet. Star the exact gate of a drop with "Star here", a Google Maps link, or by picking it on the map.' : 'Nothing matches.',
                      style: TextStyle(color: mutedColor(context)))),
                for (final x in starList)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: const CircleAvatar(backgroundColor: Color(0x22FF6B3D), child: Icon(Icons.star, color: orange)),
                    title: Text(x.s['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text([if ((x.s['note'] ?? '').toString().isNotEmpty) x.s['note'], if (x.d != null) '${geo.fmtDist(x.d!)} away'].join(' · '), maxLines: 2),
                    trailing: IconButton(icon: const Icon(Icons.navigation_outlined), tooltip: 'Navigate', onPressed: () => openUri(context, geo.googleNav(numOf(x.s['lat']), numOf(x.s['lon'])))),
                    onTap: () { map.move(LatLng(numOf(x.s['lat']), numOf(x.s['lon'])), 17); sheetCtl.animateTo(.26, duration: const Duration(milliseconds: 250), curve: Curves.easeOut); _starSheet(x.s); },
                  ),
              ]),
            ),
          ),
        ]);
      });
}

// ---- star editor ---------------------------------------------------------------------------
Future<void> starEditor(BuildContext context, J p) => sheet(context, (c) => _StarEditor(p: p));

class _StarEditor extends StatefulWidget {
  final J p;
  const _StarEditor({required this.p});
  @override
  State<_StarEditor> createState() => _StarEditorState();
}

class _StarEditorState extends State<_StarEditor> {
  late final name = TextEditingController(text: widget.p['name'] ?? ''), note = TextEditingController(text: widget.p['note'] ?? '');
  late double? lat = hasLL(widget.p) ? numOf(widget.p['lat']) : null, lon = hasLL(widget.p) ? numOf(widget.p['lon']) : null;
  String hint = '';
  bool finding = false;
  bool get isNew => widget.p['id'] == null;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(isNew ? '⭐ Star a place' : 'Edit starred place', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        TextField(controller: name, autofocus: name.text.isEmpty, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name', hintText: "e.g. Sainsbury's Paignton – goods in")),
        const SizedBox(height: 10),
        TextField(controller: note, autofocus: name.text.isNotEmpty, decoration: const InputDecoration(labelText: 'Note (gate, bay, phone…)', hintText: 'e.g. Gate 2 on Torquay Rd, ring bell')),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lat != null ? '📍 ${lat!.toStringAsFixed(6)}, ${lon!.toStringAsFixed(6)}' : 'No location yet. Adjust on the map, use where you are, or paste coordinates.',
                style: TextStyle(fontWeight: lat != null ? FontWeight.w700 : null)),
            if (hint.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(hint, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              OutlinedButton.icon(icon: const Icon(Icons.satellite_alt, size: 18), label: const Text('Adjust on map'), onPressed: () async {
                final start = lat != null ? LatLng(lat!, lon!) : store.lastPos != null ? LatLng(store.lastPos!.lat, store.lastPos!.lon) : const LatLng(52.4, -2.5);
                final spot = await pinMap(context, start, lat != null ? 18 : store.lastPos != null ? 17 : 6, 'Move the map so the pin is exactly on the gate');
                if (spot != null) setState(() { lat = spot.latitude; lon = spot.longitude; });
              }),
              OutlinedButton.icon(icon: const Icon(Icons.my_location, size: 18), label: Text(finding ? 'Finding you…' : 'Where I am'), onPressed: () async {
                setState(() => finding = true);
                try { final p = await getHere(); setState(() { lat = p.lat; lon = p.lon; }); } catch (e) { if (context.mounted) alert(context, '$e'); }
                setState(() => finding = false);
              }),
              OutlinedButton.icon(icon: const Icon(Icons.content_paste, size: 18), label: const Text('Paste'), onPressed: () async {
                final t = (await Clipboard.getData('text/plain'))?.text ?? '';
                final c = geo.parseCoords(t);
                setState(() {
                  if (c != null) { lat = c.lat; lon = c.lon; hint = ''; if (c.name.isNotEmpty && name.text.isEmpty) name.text = c.name; }
                  else { hint = geo.isShortLink(t) ? 'Short "maps.app.goo.gl" links can\'t be read. In Google Maps, press and hold the exact spot and copy the coordinates shown at the top.' : 'No coordinates found in what you copied.'; }
                });
              }),
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          if (!isNew) TextButton(onPressed: () async {
            if (!await confirm(context, 'Delete this starred place?', ok: 'Delete')) return;
            store.removeStar(widget.p['id']);
            if (context.mounted) Navigator.pop(context);
          }, child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const Spacer(),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: () {
            final n = name.text.trim();
            if (n.isEmpty) { alert(context, 'Give it a name.'); return; }
            if (lat == null) { alert(context, 'Add the location: paste a link or coordinates, or use where you are.'); return; }
            if (isNew) { store.addStar({'name': n, 'note': note.text.trim(), 'lat': lat, 'lon': lon}); }
            else { widget.p..['name'] = n..['note'] = note.text.trim()..['lat'] = lat..['lon'] = lon; store.changed(); }
            Navigator.pop(context);
            toast(context, '⭐ Saved $n');
          }, child: const Text('Save')),
        ]),
      ]);
}

// ---- pin map: move the map until the pin sits on the gate (satellite by default when zoomed in) ----------
Future<LatLng?> pinMap(BuildContext context, LatLng center, double zoom, String title) =>
    Navigator.of(context).push<LatLng>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PinMap(center: center, zoom: zoom, title: title)));

class _PinMap extends StatefulWidget {
  final LatLng center; final double zoom; final String title;
  const _PinMap({required this.center, required this.zoom, required this.title});
  @override
  State<_PinMap> createState() => _PinMapState();
}

class _PinMapState extends State<_PinMap> {
  final map = MapController();
  late bool sat = widget.zoom >= 15;
  late LatLng c = widget.center;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title, style: const TextStyle(fontSize: 16))),
        body: Stack(alignment: Alignment.center, children: [
          FlutterMap(mapController: map,
              options: MapOptions(initialCenter: widget.center, initialZoom: widget.zoom, onPositionChanged: (cam, _) => setState(() => c = cam.center),
                  interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate)),
              children: [...tilesFor(sat ? 'Satellite + roads' : 'Map'), RichAttributionWidget(attributions: [TextSourceAttribution(attributionFor(sat ? 'Satellite' : 'Map'))])]),
          const IgnorePointer(child: Padding(padding: EdgeInsets.only(bottom: 44), child: Icon(Icons.location_on, size: 48, color: orange, shadows: [Shadow(blurRadius: 6, color: Colors.black54)]))),
          Positioned(top: 12, left: 12, right: 12, child: Row(children: [
            FilledButton.tonalIcon(onPressed: () => setState(() => sat = !sat), icon: Icon(sat ? Icons.map : Icons.satellite_alt, size: 18), label: Text(sat ? 'Map' : 'Satellite')),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(onPressed: () async {
              try { final p = await getHere(); map.move(LatLng(p.lat, p.lon), 19); } catch (e) { if (context.mounted) alert(context, '$e'); }
            }, icon: const Icon(Icons.my_location, size: 18), label: const Text('Me')),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text('${c.latitude.toStringAsFixed(5)}, ${c.longitude.toStringAsFixed(5)}', style: const TextStyle(color: Colors.white, fontSize: 12))),
          ])),
        ]),
        bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: FilledButton.icon(onPressed: () => Navigator.pop(context, map.camera.center), icon: const Icon(Icons.check), label: const Text('Use this spot'))),
        ]))),
      );
}

// ---- ＋ Add place: search a name/postcode, paste a link or coordinates, here, or the map ----------------
Future<void> addPlaceFlow(BuildContext context, {Pos? near}) => sheet(context, (c) => _AddPlace(near: near, outer: context));

class _AddPlace extends StatefulWidget {
  final Pos? near; final BuildContext outer;
  const _AddPlace({this.near, required this.outer});
  @override
  State<_AddPlace> createState() => _AddPlaceState();
}

class _Hit { final String icon, name, sub; final double lat, lon; final bool keepName; _Hit(this.icon, this.name, this.sub, this.lat, this.lon, this.keepName); }

class _AddPlaceState extends State<_AddPlace> {
  final q = TextEditingController();
  Timer? t; int seq = 0;
  List<_Hit> hits = [];
  String msg = '';

  Future<void> run() async {
    final v = q.text.trim(), my = ++seq;
    if (v.isEmpty) { setState(() { hits = []; msg = ''; }); return; }
    final c = geo.parseCoords(v);
    if (c != null) { setState(() { msg = ''; hits = [_Hit('📌', c.name.isNotEmpty ? c.name : 'These coordinates', '${c.lat.toStringAsFixed(5)}, ${c.lon.toStringAsFixed(5)}', c.lat, c.lon, c.name.isNotEmpty)]; }); return; }
    if (geo.isShortLink(v)) { setState(() { hits = []; msg = "Short maps.app.goo.gl links can't be read. In Google Maps press and hold the spot and copy the coordinates instead."; }); return; }
    if (v.length < 3) return;
    setState(() => msg = 'Searching…');
    try {
      final list = await geo.search(v, nearLat: widget.near?.lat, nearLon: widget.near?.lon);
      if (my != seq || !mounted) return;
      setState(() {
        msg = list.isEmpty ? 'Nothing found. Try the postcode, or find it on the map.' : '';
        // "Sainsbury's" + Paignton -> "Sainsbury's Paignton"
        hits = [for (final r in list) _Hit('🔎', r.city.isNotEmpty && !r.name.toLowerCase().contains(r.city.toLowerCase()) && !RegExp(r'^[A-Z]{1,2}\d').hasMatch(r.name) ? '${r.name} ${r.city}' : r.name, r.sub, r.lat, r.lon, true)];
      });
    } catch (_) { if (my == seq && mounted) setState(() => msg = 'Search failed. Check your signal.'); }
  }

  Future<void> toPin(_Hit h) async {
    final outer = widget.outer;
    Navigator.pop(context);
    final spot = await pinMap(outer, LatLng(h.lat, h.lon), 18, 'Move the map so the pin is exactly on the gate');
    if (spot != null && outer.mounted) await starEditor(outer, {'name': h.keepName ? h.name : '', 'lat': spot.latitude, 'lon': spot.longitude});
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('⭐ Add a place', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: q, autofocus: true, textInputAction: TextInputAction.search, onSubmitted: (_) { t?.cancel(); run(); },
              onChanged: (_) { t?.cancel(); t = Timer(const Duration(milliseconds: 350), run); },
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search a name or postcode, or paste coordinates'))),
          IconButton.filledTonal(tooltip: 'Paste', icon: const Icon(Icons.content_paste), onPressed: () async { q.text = ((await Clipboard.getData('text/plain'))?.text ?? '').trim(); run(); }),
        ]),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg, style: TextStyle(color: mutedColor(context)))),
        for (final h in hits)
          ListTile(contentPadding: EdgeInsets.zero, leading: Text(h.icon, style: const TextStyle(fontSize: 20)), title: Text(h.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(h.sub), onTap: () => toPin(h)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _Way(icon: Icons.my_location, title: 'Where I am', sub: 'Standing at the gate', onTap: () async {
            final outer = widget.outer;
            Navigator.pop(context);
            final p = await locatePicker(outer, '⭐ Star where I am: what is this place?', offerStar: false);
            if (p == null || !outer.mounted) return;
            if (p.lat == null) { alert(outer, 'No location, so nothing was starred.'); return; }
            await starEditor(outer, {'name': p.name, 'lat': p.lat, 'lon': p.lon});
          })),
          const SizedBox(width: 10),
          Expanded(child: _Way(icon: Icons.satellite_alt, title: 'On the map', sub: 'Find the gate on satellite', onTap: () async {
            final outer = widget.outer, n = widget.near;
            Navigator.pop(context);
            final spot = await pinMap(outer, n != null ? LatLng(n.lat, n.lon) : const LatLng(52.4, -2.5), n != null ? 17 : 6, 'Zoom in and put the pin on the gate');
            if (spot != null && outer.mounted) await starEditor(outer, {'lat': spot.latitude, 'lon': spot.longitude});
          })),
        ]),
        const SizedBox(height: 10),
        Text('From Google Maps: press and hold the exact spot, tap the coordinates at the top to copy them, then tap 📋 here.', style: TextStyle(color: mutedColor(context), fontSize: 13)),
      ]);
}

class _Way extends StatelessWidget {
  final IconData icon; final String title, sub; final VoidCallback onTap;
  const _Way({required this.icon, required this.title, required this.sub, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(16),
        child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: orange), const SizedBox(height: 6), Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), Text(sub, style: TextStyle(color: mutedColor(context), fontSize: 12)),
        ]))),
      );
}

/// A starred place on the map: an orange pin with a white star, and its name once you zoom in.
class StarPin extends StatelessWidget {
  final String name;
  const StarPin({super.key, required this.name});
  @override
  Widget build(BuildContext context) {
    final zoom = MapCamera.maybeOf(context)?.zoom ?? 0;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Stack(alignment: const Alignment(0, -0.3), children: [
        const Icon(Icons.location_on, color: orange, size: 40, shadows: [Shadow(blurRadius: 4, color: Colors.black45)]),
        const Icon(Icons.star_rounded, color: Colors.white, size: 17),
      ]),
      if (zoom >= 14 && name.isNotEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: .92), borderRadius: BorderRadius.circular(8), boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)]),
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: navy)),
        ),
    ]);
  }
}
