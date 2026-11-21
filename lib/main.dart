// Arno Link v3 - Bluetooth features for the ARNO OS Desk Buddy (Android).  Created By- Arnod
// Everything else (setup, faces, AI, events, WiFi) is on the Desk Buddy web page: http://192.168.4.1
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const svcUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const rxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
const txUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
const native = MethodChannel('arno/native');
const notifChannel = EventChannel('arno/notifs');

const mediaPkgs = {
  'com.spotify.music', 'com.google.android.youtube', 'com.google.android.apps.youtube.music', 'com.vanced.android.youtube',
  'org.videolan.vlc', 'com.amazon.mp3', 'com.apple.android.music', 'in.startv.hotstar', 'com.netflix.mediaclient',
  'com.jio.media.jiobeats', 'com.gaana', 'com.mxtech.videoplayer.ad', 'com.soundcloud.android', 'deezer.android.app',
  'com.google.android.music', 'com.miui.player', 'com.sec.android.app.music', 'com.audiomack', 'com.heytap.music',
};
const skipPkgs = {'android', 'com.android.systemui', 'com.android.providers.downloads', 'com.google.android.gms', 'com.arnod.arno_link'};

String appName(String pkg) {
  const known = {
    'com.whatsapp': 'WhatsApp', 'com.whatsapp.w4b': 'WhatsApp Biz', 'com.instagram.android': 'Instagram', 'org.telegram.messenger': 'Telegram',
    'com.google.android.gm': 'Gmail', 'com.google.android.apps.messaging': 'Messages', 'com.samsung.android.messaging': 'Messages',
    'com.google.android.dialer': 'Phone', 'com.android.phone': 'Phone', 'com.truecaller': 'Truecaller', 'com.facebook.orca': 'Messenger',
    'com.twitter.android': 'X', 'com.snapchat.android': 'Snapchat', 'com.discord': 'Discord', 'com.spotify.music': 'Spotify',
    'com.google.android.youtube': 'YouTube', 'com.google.android.apps.youtube.music': 'YT Music',
  };
  if (known.containsKey(pkg)) return known[pkg]!;
  final n = pkg.split('.').last;
  return n.isEmpty ? pkg : n[0].toUpperCase() + n.substring(1);
}

class Link extends ChangeNotifier {
  late SharedPreferences prefs;
  BluetoothDevice? dev;
  BluetoothCharacteristic? rx, tx;
  StreamSubscription? _stateSub, _valSub, _scanSub, _notifSub;
  bool connected = false, connecting = false, userStopped = false, fwd = true, listenerOn = false;
  String status = 'Not connected', phoneName = 'Phone', musicTitle = '', musicApp = '', lastMsg = '';
  final Map<String, String> info = {};
  String _buf = '';
  Future<void> _chain = Future.value();
  int _retry = 0, sentCount = 0;
  Timer? _retryTimer;
  final Map<String, int> _recent = {};
  final List<String> _fwdQ = [];
  bool _fwdBusy = false;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    fwd = prefs.getBool('fwd') ?? true;
    await _perms();
    try { phoneName = await FlutterBluePlus.adapterName; } catch (_) {}
    if (phoneName.isEmpty) phoneName = 'Phone';
    await checkListener();
    _notifSub = notifChannel.receiveBroadcastStream().listen(_onNotif, onError: (_) {});
    notifyListeners();
    connect();
  }

  Future<void> _perms() async {
    try { await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.notification].request(); } catch (_) {}
  }
  Future<void> checkListener() async {
    try { listenerOn = (await native.invokeMethod('listenerEnabled')) == true; } catch (_) { listenerOn = false; }
    notifyListeners();
  }
  Future<void> openListenerSettings() async { try { await native.invokeMethod('openListener'); } catch (_) {} }
  Future<void> openWeb() async { try { await native.invokeMethod('openUrl', {'url': 'http://192.168.4.1'}); } catch (_) {} }
  void refresh() => notifyListeners();
  void _setStatus(String s) { status = s; notifyListeners(); }

  // ---- connection: own reconnect loop, works every time (no need to delete the phone's Bluetooth history)
  Future<void> connect() async {
    if (connecting || connected) return;
    userStopped = false; connecting = true; _retryTimer?.cancel();
    _setStatus('Looking for Desk Buddy...');
    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        try { await FlutterBluePlus.turnOn(); } catch (_) {}
        await Future.delayed(const Duration(seconds: 1));
      }
      BluetoothDevice? found;
      final lastId = prefs.getString('lastId');
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((rs) {
        for (final r in rs) {
          final n = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
          if (n.startsWith('ARNO') || r.advertisementData.serviceUuids.contains(Guid(svcUuid))) found ??= r.device;
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      for (var i = 0; i < 90 && found == null && FlutterBluePlus.isScanningNow; i++) { await Future.delayed(const Duration(milliseconds: 100)); }
      try { await FlutterBluePlus.stopScan(); } catch (_) {}
      await _scanSub?.cancel();
      found ??= lastId != null ? BluetoothDevice.fromId(lastId) : null;
      if (found == null) throw 'not found';
      await _open(found!);
    } catch (e) {
      connecting = false; connected = false;
      _setStatus('Not found - retrying...');
      _scheduleRetry();
    }
  }

  Future<void> _open(BluetoothDevice d) async {
    dev = d;
    await _stateSub?.cancel();
    _stateSub = d.connectionState.listen((s) { if (s == BluetoothConnectionState.disconnected && (connected || connecting)) _lost(); });
    _setStatus('Connecting...');
    try { await d.disconnect(); } catch (_) {}
    await d.connect(autoConnect: false, timeout: const Duration(seconds: 15));
    try { await d.clearGattCache(); } catch (_) {}
    try { await d.requestMtu(247); } catch (_) {}
    final svcs = await d.discoverServices();
    rx = null; tx = null;
    for (final s in svcs) {
      if (s.uuid == Guid(svcUuid)) {
        for (final c in s.characteristics) { if (c.uuid == Guid(rxUuid)) rx = c; if (c.uuid == Guid(txUuid)) tx = c; }
      }
    }
    if (rx == null || tx == null) throw 'wrong device';
    await _valSub?.cancel();
    _buf = '';
    _valSub = tx!.onValueReceived.listen(_onBytes);
    await tx!.setNotifyValue(true);
    await prefs.setString('lastId', d.remoteId.str);
    connected = true; connecting = false; _retry = 0;
    _setStatus('Connected');
    send('PN|$phoneName');
    await Future.delayed(const Duration(milliseconds: 250));
    send('I?');
  }

  void _lost() {
    connected = false; connecting = false; rx = null; tx = null; _valSub?.cancel();
    _setStatus(userStopped ? 'Disconnected' : 'Connection lost - reconnecting...');
    if (!userStopped) _scheduleRetry();
  }
  void _scheduleRetry() {
    _retryTimer?.cancel();
    final wait = Duration(seconds: (2 + _retry * 2).clamp(2, 12));
    _retry++;
    _retryTimer = Timer(wait, () { if (!connected && !connecting && !userStopped) connect(); });
  }
  Future<void> disconnect() async {
    userStopped = true; _retryTimer?.cancel();
    try { await dev?.disconnect(); } catch (_) {}
    connected = false; connecting = false;
    _setStatus('Disconnected');
  }

  // ---- protocol (one text line per message)
  void send(String s) {
    if (rx == null || !connected) return;
    final c = rx!;
    _chain = _chain.then((_) async { try { await c.write(utf8.encode('$s\n'), withoutResponse: false, allowLongWrite: true); } catch (_) {} });
  }
  void _onBytes(List<int> b) {
    _buf += utf8.decode(b, allowMalformed: true);
    int i;
    while ((i = _buf.indexOf('\n')) >= 0) {
      final line = _buf.substring(0, i).trim();
      _buf = _buf.substring(i + 1);
      if (line.isNotEmpty) _onLine(line);
    }
    if (_buf.length > 600) _buf = '';
  }
  void _onLine(String l) {
    final p = l.split('|');
    if (p.length < 2) return;
    switch (p[0]) {
      case 'I': info[p[1]] = p.length > 2 ? p.sublist(2).join('|') : ''; break;
      case 'S': if (p[1] == 'cd') _toast('Timer completed', 'Your timer on the Desk Buddy is done.'); break;
      case 'G': lastMsg = p.sublist(1).join('|'); _toast('Desk Buddy', lastMsg); break;
      case 'M': lastMsg = p.sublist(1).join('|'); _toast('Desk Buddy', lastMsg); break;
      case 'C':
        if (p[1] == 'PP') media('pp');
        if (p[1] == 'MUSIC1') _musicNow();
        break;
      default: break;
    }
    notifyListeners();
  }
  Future<void> _toast(String t, String b) async { try { await native.invokeMethod('notify', {'title': t, 'body': b}); } catch (_) {} }
  Future<void> media(String k) async { try { await native.invokeMethod('media', {'key': k}); } catch (_) {} }
  Future<void> setFwd(bool v) async { fwd = v; await prefs.setBool('fwd', v); notifyListeners(); }

  // ---- phone notifications -> Desk Buddy (and media notifications -> music mode)
  void _onNotif(dynamic ev) {
    if (ev is! Map) return;
    final pkg = (ev['pkg'] ?? '') as String, title = ((ev['title'] ?? '') as String).trim(), text = ((ev['text'] ?? '') as String).trim();
    final removed = ev['removed'] == true;
    if (skipPkgs.contains(pkg)) return;
    if (mediaPkgs.contains(pkg)) {
      if (removed) { if (musicApp == appName(pkg)) { musicTitle = ''; send('MU|2|||'); } }
      else if (title.isNotEmpty) { musicTitle = title; musicApp = appName(pkg); _musicSend(text); }
      notifyListeners();
      return;
    }
    if (!fwd || !connected || removed || (title.isEmpty && text.isEmpty)) return;
    final key = '$pkg|$title|$text';
    final now = DateTime.now().millisecondsSinceEpoch;
    _recent.removeWhere((_, t) => now - t > 8000);
    if (_recent.containsKey(key)) return;
    _recent[key] = now;
    String c(String s, int n) => (s.length > n ? s.substring(0, n) : s).replaceAll('|', '/').replaceAll('\n', ' ');
    _fwdQ.add('N|${c(appName(pkg), 18)}|${c(title, 30)}|${c(text, 160)}');
    if (_fwdQ.length > 6) _fwdQ.removeAt(0);
    _drain();
  }
  Future<void> _drain() async {
    if (_fwdBusy) return;
    _fwdBusy = true;
    while (_fwdQ.isNotEmpty) { send(_fwdQ.removeAt(0)); sentCount++; notifyListeners(); await Future.delayed(const Duration(milliseconds: 700)); }
    _fwdBusy = false;
  }
  void _musicSend(String artist) {
    String c(String s, int n) => (s.length > n ? s.substring(0, n) : s).replaceAll('|', '/').replaceAll('\n', ' ');
    send('MU|1|${c(musicApp, 20)}|${c(musicTitle, 60)}|${c(artist, 36)}');
  }
  void _musicNow() { if (musicTitle.isNotEmpty) _musicSend(''); else send('MU|2|||'); }
}

final link = Link();
final accent = ValueNotifier<int>(0xFF1FB5C9);
final dark = ValueNotifier<bool>(true);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  accent.value = p.getInt('accent') ?? 0xFF1FB5C9;
  dark.value = p.getBool('dark') ?? true;
  runApp(const ArnoApp());
}

class ArnoApp extends StatelessWidget {
  const ArnoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([accent, dark]),
      builder: (_, __) {
        final seed = Color(accent.value);
        return MaterialApp(
          title: 'Arno Link', debugShowCheckedModeBanner: false,
          themeMode: dark.value ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light)),
          darkTheme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: const Color(0xFF08121B), colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark, surface: const Color(0xFF0E1D2B))),
          home: const Home(),
        );
      },
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); link.init(); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) link.checkListener(); }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: link, builder: (_, __) {
      final cs = Theme.of(context).colorScheme;
      const colors = [0xFF1FB5C9, 0xFF4CAF50, 0xFFFF9800, 0xFFE91E63, 0xFF7C4DFF, 0xFFF44336, 0xFF2196F3];
      return Scaffold(
        appBar: AppBar(title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Text('Arno Link', style: TextStyle(fontWeight: FontWeight.w800)), Text('Created By- Arnod', style: TextStyle(fontSize: 11)),
        ])),
        body: ListView(padding: const EdgeInsets.all(14), children: [
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(link.connected ? Icons.bluetooth_connected : Icons.bluetooth_searching, color: link.connected ? Colors.green : Colors.orange, size: 30),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(link.connected ? (link.info['dev'] ?? 'Desk Buddy') : 'Desk Buddy', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                Text(link.status, style: TextStyle(color: cs.onSurfaceVariant)),
              ])),
              FilledButton.tonal(onPressed: link.connected ? link.disconnect : link.connect, child: Text(link.connected ? 'Disconnect' : 'Connect')),
            ]),
            if (link.connected) Padding(padding: const EdgeInsets.only(top: 10), child: Text('User: ${link.info['user'] ?? '-'}   OS: ${link.info['os'] ?? '-'}   WiFi: ${link.info['wifi'] ?? '-'}', style: const TextStyle(fontSize: 12))),
            const SizedBox(height: 6),
            const Text('When connected, the Desk Buddy greets you and shows "Connected to Bluetooth" with your phone name.', style: TextStyle(fontSize: 12)),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Web control', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Setup, faces, Buddy AI, events, WiFi and Gemini key are on the Desk Buddy web page. Join the WiFi "Arno OS-Setup" (password Arnod1702), then open it:', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            FilledButton.icon(onPressed: link.openWeb, icon: const Icon(Icons.language), label: const Text('Open http://192.168.4.1')),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Phone notifications on Desk Buddy', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: link.fwd, onChanged: link.setFwd, title: const Text('Forward notifications'), subtitle: Text('${link.sentCount} sent this session')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(link.listenerOn ? Icons.check_circle : Icons.error_outline, color: link.listenerOn ? Colors.green : Colors.orange),
              title: Text(link.listenerOn ? 'Notification access is ON' : 'Notification access is OFF'),
              subtitle: Text(link.listenerOn ? 'Also set battery to Unrestricted for Arno Link.' : 'Tap Grant, find "Arno Link" in the list and switch it on.'),
              trailing: FilledButton.tonal(onPressed: link.openListenerSettings, child: Text(link.listenerOn ? 'Open' : 'Grant')),
            ),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
            const Align(alignment: Alignment.centerLeft, child: Text('Music control', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            const SizedBox(height: 6),
            Text(link.musicTitle.isEmpty ? 'Nothing playing on this phone' : '${link.musicApp}: ${link.musicTitle}', maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              IconButton.filledTonal(onPressed: () => link.media('prev'), icon: const Icon(Icons.skip_previous)),
              IconButton.filled(iconSize: 32, onPressed: () => link.media('pp'), icon: const Icon(Icons.play_arrow)),
              IconButton.filledTonal(onPressed: () => link.media('next'), icon: const Icon(Icons.skip_next)),
            ]),
            const SizedBox(height: 6),
            const Text('On the Desk Buddy: 5 taps = music mode. Then 2 taps = play/pause, 1 tap = exit.', style: TextStyle(fontSize: 12)),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Look', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: dark.value, onChanged: (v) async { dark.value = v; (await SharedPreferences.getInstance()).setBool('dark', v); }, title: const Text('Dark mode')),
            Wrap(spacing: 10, children: [
              for (final c in colors)
                GestureDetector(
                  onTap: () async { accent.value = c; (await SharedPreferences.getInstance()).setInt('accent', c); },
                  child: CircleAvatar(radius: 17, backgroundColor: Color(c), child: accent.value == c ? const Icon(Icons.check, color: Colors.white, size: 18) : null),
                ),
            ]),
          ]))),
          const SizedBox(height: 10),
          Center(child: Text('Arno Link v3 - Created By- Arnod', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))),
        ]),
      );
    });
  }
}
