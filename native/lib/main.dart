// Tuki: map-first driver app — starred places, diary, tacho timesheet.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/week.dart';
import 'data/store.dart';
import 'ui/common.dart';
import 'ui/diary_tab.dart';
import 'ui/here.dart';
import 'ui/incoming.dart';
import 'ui/map_tab.dart';
import 'ui/me_tab.dart';
import 'ui/sheet_tab.dart';
import 'web_demo.dart';

const _incoming = MethodChannel('tuki/incoming');

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
  late final here = HereWatch(context: () => context, openDay: openDay);

  String _latestWeek() {
    final p = store.prep;
    return p != null && p.shifts.isNotEmpty ? sundayOf(p.shifts.last.cardIn) : sundayOf(DateTime.now().millisecondsSinceEpoch);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb) return;
    here.init();
    _incoming.setMethodCallHandler((call) async { if (call.method == 'incoming') _open(call.arguments as Map); });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final first = await _incoming.invokeMethod<Map>('initial');
      if (first != null) _open(first);
      _checkUpdate();
    });
  }

  void _open(Map item) => handleIncoming(context, item, openWeek: openWeek, openDay: openDay, openMap: () => setState(() => tab = 0));

  Future<void> _checkUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final r = await http.get(Uri.parse('https://api.github.com/repos/yessirks/tacho-timesheet/releases/tags/tuki-native-latest')).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final name = (jsonDecode(r.body)['name'] ?? '') as String; // "Tuki native 2.0.7"
      final latest = int.tryParse(RegExp(r'(\d+)$').firstMatch(name)?[1] ?? '') ?? 0, mine = int.tryParse(info.buildNumber) ?? 0;
      if (latest > mine) {
        updateAvailable.value = name.replaceFirst('Tuki native ', '');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('A new Tuki (${updateAvailable.value}) is ready'), duration: const Duration(seconds: 8), behavior: SnackBarBehavior.floating,
          action: SnackBarAction(label: 'Download', onPressed: () => launchUrl(Uri.parse(releaseUrl), mode: LaunchMode.externalApplication)),
        ));
      }
    } catch (_) { /* offline: try next time */ }
  }

  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); here.dispose(); super.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) here.setForeground(true);
    if (s == AppLifecycleState.paused) { here.setForeground(false); store.saveNow(); }
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
          onDestinationSelected: (i) { if (i == 1 && tab != 1) day.value = todayKey(); setState(() => tab = i); if (!kIsWeb) here.setForeground(true); },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
            NavigationDestination(icon: Icon(Icons.edit_calendar_outlined), selectedIcon: Icon(Icons.edit_calendar), label: 'Diary'),
            NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: 'Timesheet'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Me'),
          ],
        ),
      );
}
