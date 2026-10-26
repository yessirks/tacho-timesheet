// Tuki: map-first driver app — starred places, diary, tacho timesheet.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'core/week.dart';
import 'data/store.dart';
import 'ui/common.dart';
import 'ui/diary_tab.dart';
import 'ui/map_tab.dart';
import 'ui/me_tab.dart';
import 'ui/sheet_tab.dart';
import 'web_demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  london; // load the UK time zone once
  await AppStore.I.load(demo: kIsWeb ? webDemo : null);
  runApp(const TukiApp());
}

class TukiApp extends StatelessWidget {
  const TukiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tuki', debugShowCheckedModeBanner: false,
        theme: tukiTheme(Brightness.light), darkTheme: tukiTheme(Brightness.dark),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int tab = 0; // Tuki always opens on the map
  final day = ValueNotifier(todayKey());
  late final week = ValueNotifier(_latestWeek());
  StreamSubscription<Position>? here;
  String hereShown = '';

  String _latestWeek() {
    final p = store.prep;
    return p != null && p.shifts.isNotEmpty ? sundayOf(p.shifts.last.cardIn) : sundayOf(DateTime.now().millisecondsSinceEpoch);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startHere();
  }

  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); here?.cancel(); super.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) { _startHere(); } else if (s == AppLifecycleState.paused) { here?.cancel(); here = null; store.saveNow(); }
  }

  // Live: while Tuki is open, notice arriving at a starred / saved place and offer to add it to today.
  Future<void> _startHere() async {
    if (here != null || store.profile['hereAlerts'] == 'no') return;
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return;
    here = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25)).listen((p) {
      store.lastPos = Pos(p.latitude, p.longitude, p.accuracy, p.timestamp.millisecondsSinceEpoch);
      final pl = store.placeAt(p.latitude, p.longitude, p.accuracy);
      if (pl == null) return;
      store.logVisit(pl.name, pl.lat, pl.lon, p.timestamp.millisecondsSinceEpoch);
      _offer(pl.name, pl.lat, pl.lon);
    }, onError: (_) {});
  }

  void _offer(String name, double lat, double lon) {
    final d = todayKey(), key = '$d|$name';
    if (hereShown == key || store.inDay(d, name) || store.dismissed(d, name) || !mounted) return;
    hereShown = key;
    HapticFeedback.mediumImpact();
    final m = ScaffoldMessenger.of(context);
    void add(String type) {
      m.hideCurrentMaterialBanner();
      store.addStopTo(d, {'type': type, 'name': name, 'lat': lat, 'lon': lon});
      toast(context, 'Added ${stopTypes[type]} $name to today');
      if (type == 'couple') { day.value = d; setState(() => tab = 1); toast(context, 'Type the trailer number on the Couple line'); }
    }
    m.showMaterialBanner(MaterialBanner(
      leading: const Icon(Icons.location_on, color: orange),
      content: Text.rich(TextSpan(children: [TextSpan(text: "You're at $name\n", style: const TextStyle(fontWeight: FontWeight.w800)), const TextSpan(text: "Add it to today's diary?")])),
      actions: [
        FilledButton(onPressed: () => add('drop'), child: const Text('Drop')),
        TextButton(onPressed: () => add('pickup'), child: const Text('Pickup')),
        TextButton(onPressed: () => add('couple'), child: const Text('Couple')),
        IconButton(tooltip: 'Not now', onPressed: () { m.hideCurrentMaterialBanner(); store.dismiss(d, name); }, icon: const Icon(Icons.close)),
      ],
    ));
  }

  void openDay(String d) { day.value = d; setState(() => tab = 1); }
  void openWeek(String sun) { week.value = sun; setState(() => tab = 2); }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: tab, children: [
          MapTab(openDay: openDay),
          DiaryTab(day: day, openWeek: openWeek),
          SheetTab(week: week),
          const MeTab(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) { if (i == 1 && tab != 1) day.value = todayKey(); setState(() => tab = i); _startHere(); },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
            NavigationDestination(icon: Icon(Icons.edit_calendar_outlined), selectedIcon: Icon(Icons.edit_calendar), label: 'Diary'),
            NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: 'Timesheet'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Me'),
          ],
        ),
      );
}
