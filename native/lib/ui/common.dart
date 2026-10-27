// Shared UI: theme, small helpers, location, the type-ahead place field and the "where am I?" picker.
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../core/geo.dart' as geo;
import '../data/store.dart';

AppStore get store => AppStore.I;

const releaseUrl = 'https://github.com/yessirks/tacho-timesheet/releases/download/tuki-native-latest/Tuki-native.apk';
/// A newer APK on GitHub than the one installed (checked once per start).
final updateAvailable = ValueNotifier<String?>(null);

// ---- theme --------------------------------------------------------------------------
const navy = Color(0xFF0A1430), navy2 = Color(0xFF16224D), orange = Color(0xFFFF6B3D), amber = Color(0xFFFFB547);

ThemeData tukiTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: orange, brightness: b).copyWith(
    primary: dark ? const Color(0xFFFF8A5C) : const Color(0xFFE5532A),
    onPrimary: Colors.white,
    secondary: dark ? const Color(0xFF8FB1FF) : const Color(0xFF1E4FCC),
    surface: dark ? const Color(0xFF0E1630) : Colors.white,
    surfaceContainerLowest: dark ? const Color(0xFF0A1128) : const Color(0xFFF4F6FB),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b);
  return base.copyWith(
    scaffoldBackgroundColor: dark ? const Color(0xFF080E22) : const Color(0xFFEEF2F8),
    appBarTheme: const AppBarTheme(backgroundColor: navy, foregroundColor: Colors.white, elevation: 0, centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light),
    cardTheme: CardThemeData(elevation: 0, color: scheme.surface, margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: dark ? const Color(0xFF1E2A50) : const Color(0xFFE1E7F2)))),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true, filled: true, fillColor: dark ? const Color(0xFF121C3C) : const Color(0xFFF4F6FB),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF0B1330) : Colors.white, indicatorColor: orange.withValues(alpha: 0.18), height: 66,
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ),
    chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
  );
}

/// The Tuki logo: a white T whose stem ends in a map-pin point, on blue (matches the launcher icon).
class TukiMark extends StatelessWidget {
  final double size;
  const TukiMark({super.key, this.size = 30});
  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * 0.24),
            gradient: const LinearGradient(colors: [Color(0xFF1E66F5), navy], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: CustomPaint(painter: _TPainter()),
      );
}

class _TPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final k = s.width / 512;
    Offset o(double x, double y) => Offset(x * k, y * k);
    final p = Path()
      ..moveTo(150 * k, 132 * k)..lineTo(362 * k, 132 * k)
      ..arcToPoint(o(362, 200), radius: Radius.circular(34 * k))
      ..lineTo(294 * k, 200 * k)..lineTo(294 * k, 330 * k)
      ..cubicTo(294 * k, 356 * k, 274 * k, 378 * k, 256 * k, 404 * k)
      ..cubicTo(238 * k, 378 * k, 218 * k, 356 * k, 218 * k, 330 * k)
      ..lineTo(218 * k, 200 * k)..lineTo(150 * k, 200 * k)
      ..arcToPoint(o(150, 132), radius: Radius.circular(34 * k))..close();
    c.drawPath(p, Paint()..color = Colors.white);
    c.drawCircle(o(256, 166), 17 * k, Paint()..color = orange);
  }
  @override
  bool shouldRepaint(_) => false;
}

// ---- small helpers ---------------------------------------------------------------------
void toast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)));
}

Future<bool> confirm(BuildContext context, String text, {String ok = 'OK'}) async =>
    await showDialog<bool>(context: context, builder: (c) => AlertDialog(content: Text(text), actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ])) ?? false;

Future<void> alert(BuildContext context, String text) => showDialog(context: context, builder: (c) => AlertDialog(content: Text(text),
    actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]));

Future<T?> sheet<T>(BuildContext context, Widget Function(BuildContext) builder, {bool full = false}) => showModalBottomSheet<T>(
      context: context, isScrollControlled: true, useSafeArea: true, showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
        child: full ? builder(c) : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 0, 18, 18), child: builder(c)),
      ),
    );

class SectionTitle extends StatelessWidget {
  final String text; final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Row(children: [Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: .2))), ?trailing]),
      );
}

Color mutedColor(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: .6);

/// Pick one file from the phone; null when cancelled.
Future<({String name, String? ext, Uint8List bytes})?> pickOne({FileType type = FileType.any, List<String>? extensions}) async {
  final r = await FilePicker.pickFiles(type: type, allowedExtensions: extensions);
  if (r.isEmpty) return null;
  final f = r.first;
  return (name: f.name, ext: f.extension?.toLowerCase(), bytes: await f.xFile.readAsBytes());
}

// ---- location -------------------------------------------------------------------------------
Future<Pos> getHere() async {
  if (!await Geolocator.isLocationServiceEnabled()) throw 'Location is switched off. Turn it on in the quick settings.';
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'Tuki is not allowed to use your location. Allow it in the app settings.';
  try {
    final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
    final pos = Pos(p.latitude, p.longitude, p.accuracy, p.timestamp.millisecondsSinceEpoch);
    store.lastPos = pos;
    return pos;
  } on TimeoutException {
    throw 'Getting your location took too long. Try again outside or with GPS on.';
  }
}

// ---- a text field that keeps in step with the store without fighting your typing --------------
class SyncedField extends StatefulWidget {
  final String value; final ValueChanged<String> onChanged; final ValueChanged<String>? onDone;
  final String? label, hint; final TextInputType? keyboard; final Widget? suffix; final int maxLines; final bool bold;
  const SyncedField({super.key, required this.value, required this.onChanged, this.onDone, this.label, this.hint, this.keyboard, this.suffix, this.maxLines = 1, this.bold = false});
  @override
  State<SyncedField> createState() => _SyncedFieldState();
}

class _SyncedFieldState extends State<SyncedField> {
  late final c = TextEditingController(text: widget.value);
  final f = FocusNode();
  @override
  void initState() { super.initState(); f.addListener(() { if (!f.hasFocus) widget.onDone?.call(c.text); }); }
  @override
  void didUpdateWidget(covariant SyncedField old) {
    super.didUpdateWidget(old);
    if (!f.hasFocus && c.text != widget.value) c.text = widget.value;
  }
  @override
  void dispose() { c.dispose(); f.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => TextField(
        controller: c, focusNode: f, keyboardType: widget.keyboard, maxLines: widget.maxLines, onChanged: widget.onChanged,
        style: widget.bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
        decoration: InputDecoration(labelText: widget.label, hintText: widget.hint, suffixIcon: widget.suffix),
      );
}

/// Place name field with suggestions from starred places, saved places and your diary (your usual route first).
class PlaceField extends StatefulWidget {
  final String value; final ValueChanged<String> onChanged; final void Function(Suggestion)? onPick; final VoidCallback? onLocate;
  final String? label, hint; final String? Function()? prev; final ValueChanged<String>? onDone;
  const PlaceField({super.key, required this.value, required this.onChanged, this.onPick, this.onLocate, this.label, this.hint, this.prev, this.onDone});
  @override
  State<PlaceField> createState() => _PlaceFieldState();
}

class _PlaceFieldState extends State<PlaceField> {
  late final c = TextEditingController(text: widget.value);
  final f = FocusNode();
  @override
  void initState() { super.initState(); f.addListener(() { if (!f.hasFocus) widget.onDone?.call(c.text); }); }
  @override
  void didUpdateWidget(covariant PlaceField old) {
    super.didUpdateWidget(old);
    if (!f.hasFocus && c.text != widget.value) c.text = widget.value;
  }
  @override
  void dispose() { c.dispose(); f.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => RawAutocomplete<Suggestion>(
        textEditingController: c, focusNode: f,
        optionsBuilder: (v) {
          final list = store.placeSuggestions(v.text, prev: widget.prev?.call());
          if (list.length == 1 && list.first.name.toLowerCase() == v.text.trim().toLowerCase()) return const [];
          return list;
        },
        displayStringForOption: (s) => s.name,
        onSelected: (s) { widget.onChanged(s.name); widget.onPick?.call(s); widget.onDone?.call(s.name); f.unfocus(); },
        fieldViewBuilder: (ctx, ctl, fn, submit) => TextField(
          controller: ctl, focusNode: fn, onChanged: widget.onChanged, textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: widget.label, hintText: widget.hint,
              suffixIcon: widget.onLocate == null ? null : IconButton(tooltip: 'Use my location', icon: const Icon(Icons.my_location, size: 20), onPressed: widget.onLocate)),
        ),
        optionsViewBuilder: (ctx, onSel, opts) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6, borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300, maxWidth: 420),
              child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), shrinkWrap: true, children: [
                for (final s in opts)
                  ListTile(
                    dense: true, leading: Text(s.icon, style: const TextStyle(fontSize: 18)), title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${s.sub}${s.d != null ? ' · ${geo.fmtDist(s.d!)}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => onSel(s),
                  ),
              ]),
            ),
          ),
        ),
      );
}

// ---- 📍 "where am I?" picker: starred spots, saved places, shops and depots nearby, the town ----------
class Picked { final String name; final double? lat, lon; Picked(this.name, [this.lat, this.lon]); }

Future<Picked?> locatePicker(BuildContext context, String title, {bool offerStar = true}) =>
    sheet<Picked>(context, (c) => _LocatePicker(title: title, offerStar: offerStar));

class _LocatePicker extends StatefulWidget {
  final String title; final bool offerStar;
  const _LocatePicker({required this.title, required this.offerStar});
  @override
  State<_LocatePicker> createState() => _LocatePickerState();
}

class _Item { final String name, sub; final double? lat, lon; final bool exact; _Item(this.name, this.sub, {this.lat, this.lon, this.exact = false}); }

class _LocatePickerState extends State<_LocatePicker> {
  String status = 'Getting your location…';
  bool busy = false, star = false, searching = true;
  Pos? pos;
  final items = <_Item>[], seen = <String>{};
  final own = TextEditingController();

  void _add(_Item it) { if (seen.add(it.name.toLowerCase())) items.add(it); }

  @override
  void initState() { super.initState(); _run(); }

  Future<void> _run() async {
    try { pos = await getHere(); } catch (e) { if (mounted) setState(() { status = '$e You can still type a name.'; searching = false; }); return; }
    if (!mounted) return;
    final p = pos!;
    final starred = [for (final s in store.stars) (s: s, d: geo.distM(p.lat, p.lon, numOf(s['lat']), numOf(s['lon'])))]..removeWhere((x) => x.d > 400)..sort((a, b) => a.d.compareTo(b.d));
    for (final x in starred) { _add(_Item(x.s['name'], '⭐ starred · ${geo.fmtDist(x.d)}', lat: numOf(x.s['lat']), lon: numOf(x.s['lon']), exact: true)); }
    final sp = store.savedAt(p.ll);
    if (sp != null && (sp['name'] ?? '').toString().isNotEmpty) _add(_Item(sp['name'], 'saved place'));
    setState(() => status = 'Found you (±${p.acc.round()} m). Looking for shops and depots nearby…');
    await _nearby(p);
  }

  Future<void> _nearby(Pos p) async {
    geo.Reverse? rev;
    var near = <geo.NearPlace>[];
    busy = false;
    await Future.wait([
      () async { try { rev = await geo.reverse(p.lat, p.lon); } catch (_) {} }(),
      () async { try { near = await geo.nearby(p.lat, p.lon); } catch (_) { busy = true; } }(),
    ]);
    if (!mounted) return;
    final town = rev?.town ?? '';
    for (final n in near) {
      final t = n.city.isNotEmpty ? n.city : town;
      _add(_Item(t.isNotEmpty && !n.name.toLowerCase().contains(t.toLowerCase()) ? '${n.name} $t' : n.name, '${n.kind.isEmpty ? 'place' : n.kind} · ${geo.fmtDist(n.dist)}'));
    }
    if (town.isNotEmpty) _add(_Item(town, 'town${rev!.postcode.isNotEmpty ? ' · ${rev!.postcode}' : ''}'));
    if (rev != null && rev!.road.isNotEmpty && town.isNotEmpty) _add(_Item('${rev!.road}, $town', 'street'));
    setState(() {
      searching = false;
      status = 'Found you (±${p.acc.round()} m). Pick the place, or type it:${busy ? '' : near.isEmpty ? ' (nothing named nearby on the map)' : ''}';
    });
  }

  void _pick(String name, {double? lat, double? lon}) {
    name = name.trim();
    if (name.isEmpty) return;
    final la = lat ?? pos?.lat, lo = lon ?? pos?.lon;
    if (star && la != null) store.addStar({'name': name, 'lat': la, 'lon': lo});
    Navigator.pop(context, Picked(name, la, lo));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Row(children: [
          if (searching) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
          Expanded(child: Text(status, style: TextStyle(color: mutedColor(context)))),
        ]),
        if (busy) Row(children: [
          Expanded(child: Text('The map server is busy, so shops and depots nearby are missing.', style: TextStyle(color: Theme.of(context).colorScheme.error))),
          TextButton(onPressed: () { setState(() { busy = false; searching = true; }); _nearby(pos!); }, child: const Text('Try again')),
        ]),
        const SizedBox(height: 8),
        for (final it in items)
          ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(it.sub),
              onTap: () => _pick(it.name, lat: it.exact ? it.lat : null, lon: it.exact ? it.lon : null)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: PlaceField(value: '', hint: 'Or type a name', onChanged: (v) => own.text = v,
              onPick: (s) => _pick(s.name, lat: s.lat, lon: s.lon))),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => _pick(own.text), child: const Text('Use')),
        ]),
        if (widget.offerStar)
          CheckboxListTile(contentPadding: EdgeInsets.zero, value: star, onChanged: (v) => setState(() => star = v ?? false),
              title: const Text('⭐ Also star this exact spot (for sat-nav)'), controlAffinity: ListTileControlAffinity.leading, dense: true),
      ]);
}
