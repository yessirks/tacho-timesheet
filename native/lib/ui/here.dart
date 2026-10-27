// "You're at …": notices arriving at a starred / saved place and offers to add it to that day's diary.
// While Tuki is open it shows a banner; with "also when Tuki is closed" a location service keeps running
// (Android shows its notification) and arrivals come as a notification with Drop / Pickup buttons.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import '../core/week.dart';
import '../data/store.dart';
import 'common.dart';

class HereWatch {
  HereWatch({required this.context, required this.openDay});
  final BuildContext Function() context;
  final void Function(String date) openDay;

  final _notes = FlutterLocalNotificationsPlugin();
  StreamSubscription<Position>? _sub;
  String _mode = '', _shown = '';
  bool foreground = true;

  String get mode => (store.profile['hereAlerts'] as String?) ?? 'yes'; // yes = while open, always, no

  Future<void> init() async {
    await _notes.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_tuki')),
      onDidReceiveNotificationResponse: (r) => _act(r.actionId, r.payload),
    );
    final launch = await _notes.getNotificationAppLaunchDetails();
    final r = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && r != null) _act(r.actionId, r.payload);
    store.addListener(() { if (mode != _mode) restart(); });
    await restart();
  }

  Future<void> restart() async {
    await _sub?.cancel();
    _sub = null;
    _mode = mode;
    if (mode == 'no' || (mode == 'yes' && !foreground)) return;
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return;
    if (mode == 'always') {
      await _notes.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    }
    final LocationSettings settings = mode == 'always'
        ? AndroidSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 40, intervalDuration: const Duration(seconds: 20),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Tuki', notificationText: 'Watching for your starred places', notificationChannelName: 'Arrival alerts (running)',
              notificationIcon: AndroidResource(name: 'ic_stat_tuki'), setOngoing: true, color: orange,
            ))
        : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25);
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPos, onError: (_) {});
  }

  /// The app went to the background or came back.
  void setForeground(bool fg) {
    foreground = fg;
    if (mode == 'yes') { if (fg) { if (_sub == null) restart(); } else { _sub?.cancel(); _sub = null; } }
    if (mode == 'always' && _sub == null && fg) restart();
  }

  void _onPos(Position p) {
    store.lastPos = Pos(p.latitude, p.longitude, p.accuracy, p.timestamp.millisecondsSinceEpoch);
    final pl = store.placeAt(p.latitude, p.longitude, p.accuracy);
    if (pl == null) return;
    store.logVisit(pl.name, pl.lat, pl.lon, p.timestamp.millisecondsSinceEpoch);
    final d = todayKey(), key = '$d|${pl.name}';
    if (_shown == key || store.inDay(d, pl.name) || store.dismissed(d, pl.name)) return;
    _shown = key;
    final payload = jsonEncode({'d': d, 'n': pl.name, 'lat': pl.lat, 'lon': pl.lon});
    if (foreground) { _banner(payload); } else { _notify(payload, pl.name); }
  }

  Future<void> _notify(String payload, String name) => _notes.show(
        id: name.hashCode & 0x7fffffff, title: "You're at $name", body: "Add it to today's diary?", payload: payload,
        notificationDetails: const NotificationDetails(android: AndroidNotificationDetails(
          'arrivals', 'Arrivals', channelDescription: "You're at a starred place", importance: Importance.high, priority: Priority.high, color: orange,
          actions: [
            AndroidNotificationAction('drop', 'Drop', showsUserInterface: true),
            AndroidNotificationAction('pickup', 'Pickup', showsUserInterface: true),
            AndroidNotificationAction('no', 'Not now', cancelNotification: true),
          ],
        )),
      );

  void _banner(String payload) {
    final ctx = context(), j = jsonDecode(payload) as Map;
    HapticFeedback.mediumImpact();
    final m = ScaffoldMessenger.of(ctx);
    void go(String a) { m.hideCurrentMaterialBanner(); _act(a, payload); }
    m.showMaterialBanner(MaterialBanner(
      leading: const Icon(Icons.location_on, color: orange),
      content: Text.rich(TextSpan(children: [TextSpan(text: "You're at ${j['n']}\n", style: const TextStyle(fontWeight: FontWeight.w800)), const TextSpan(text: "Add it to today's diary?")])),
      actions: [
        FilledButton(onPressed: () => go('drop'), child: const Text('Drop')),
        TextButton(onPressed: () => go('pickup'), child: const Text('Pickup')),
        TextButton(onPressed: () => go('couple'), child: const Text('Couple')),
        IconButton(tooltip: 'Not now', onPressed: () => go('no'), icon: const Icon(Icons.close)),
      ],
    ));
  }

  void _act(String? action, String? payload) {
    if (payload == null) return;
    final j = jsonDecode(payload) as Map, d = j['d'] as String, name = j['n'] as String;
    if (action == 'no') { store.dismiss(d, name); return; }
    if (action == null) { openDay(d); return; } // tapped the notification itself: the diary shows "Were you here?"
    store.addStopTo(d, {'type': action, 'name': name, 'lat': j['lat'], 'lon': j['lon']});
    final ctx = context();
    if (ctx.mounted) toast(ctx, 'Added ${stopTypes[action]} $name to ${d == todayKey() ? 'today' : fmtDay(d)}');
    if (action == 'couple') { openDay(d); if (ctx.mounted) toast(ctx, 'Type the trailer number on the Couple line'); }
  }

  void dispose() => _sub?.cancel();
}
