import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

const navy = Color(0xFF0B1F44), blue = Color(0xFF1E6CFF), orange = Color(0xFFFF7A1A);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
  options: const FirebaseOptions(
    apiKey: 'YOUR_API_KEY',
    appId: 'YOUR_APP_ID',
    messagingSenderId: 'YOUR_PROJECT_NUMBER',
    projectId: 'YOUR_PROJECT_ID',
  ),
);
}

class GroupRiderApp extends StatelessWidget {
  const GroupRiderApp({super.key});
  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: b, primary: b == Brightness.light ? navy : blue, secondary: orange),
        cardTheme: CardTheme(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      );
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'GROUP RIDER',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (c, s) => s.data == null ? const LoginPage() : const HomePage(),
        ),
      );
}

// ---------- LOGIN / REGISTER ----------
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final name = TextEditingController(), email = TextEditingController(), pass = TextEditingController();
  bool register = false, busy = false;
  String? err;

  Future<void> submit() async {
    setState(() { busy = true; err = null; });
    try {
      final a = FirebaseAuth.instance;
      if (register) {
        final cred = await a.createUserWithEmailAndPassword(email: email.text.trim(), password: pass.text);
        await cred.user!.updateDisplayName(name.text.trim());
      } else {
        await a.signInWithEmailAndPassword(email: email.text.trim(), password: pass.text);
      }
    } on FirebaseAuthException catch (e) {
      err = e.message;
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 40),
            const Text('GROUP RIDER', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: orange)),
            const Text('Stay Together. Travel Together. Arrive Together.'),
            const SizedBox(height: 32),
            if (register) TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (6+ characters)')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
            const SizedBox(height: 16),
            FilledButton(onPressed: busy ? null : submit, child: Text(register ? 'Create account' : 'Sign in')),
            TextButton(onPressed: () => setState(() => register = !register), child: Text(register ? 'I have an account' : 'New here? Register')),
          ]),
        ),
      );
}

// ---------- HOME: MY GROUPS, CREATE, JOIN ----------
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<String?> ask(BuildContext c, String title) {
    final t = TextEditingController();
    return showDialog<String>(
      context: c,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: t, autofocus: true, textCapitalization: TextCapitalization.characters),
        actions: [TextButton(onPressed: () => Navigator.pop(c, t.text.trim()), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final me = FirebaseAuth.instance.currentUser!;
    final db = FirebaseFirestore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('GROUP RIDER'), actions: [
        IconButton(icon: const Icon(Icons.logout), onPressed: () => FirebaseAuth.instance.signOut()),
      ]),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('groups').where('members', arrayContains: me.uid).snapshots(),
        builder: (c, s) {
          final docs = s.data?.docs ?? [];
          if (docs.isEmpty) return const Center(child: Text('No groups yet.\nCreate one or join with a code.', textAlign: TextAlign.center));
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final d in docs)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.groups, color: blue),
                    title: Text(d['name']),
                    subtitle: Text('Code: ${d['code']}  •  ${(d['members'] as List).length} members${d['leader'] == me.uid ? '  •  Leader' : ''}'),
                    onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => GroupPage(id: d.id))),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        FloatingActionButton.extended(
          heroTag: 'join',
          icon: const Icon(Icons.login),
          label: const Text('Join'),
          onPressed: () async {
            final code = (await ask(c, 'Enter invitation code'))?.toUpperCase();
            if (code == null || code.isEmpty) return;
            final q = await db.collection('groups').where('code', isEqualTo: code).limit(1).get();
            if (q.docs.isEmpty) {
              if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Code not found')));
              return;
            }
            await q.docs.first.reference.update({'members': FieldValue.arrayUnion([me.uid])});
          },
        ),
        const SizedBox(width: 12),
        FloatingActionButton.extended(
          heroTag: 'create',
          backgroundColor: orange,
          icon: const Icon(Icons.add),
          label: const Text('Create'),
          onPressed: () async {
            final n = await ask(c, 'Group name');
            if (n == null || n.isEmpty) return;
            const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
            final r = Random.secure();
            final code = List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
            await db.collection('groups').add({'name': n, 'code': code, 'leader': me.uid, 'members': [me.uid], 'created': FieldValue.serverTimestamp()});
          },
        ),
      ]),
    );
  }
}

// ---------- GROUP RADAR (live map) ----------
class GroupPage extends StatefulWidget {
  final String id;
  const GroupPage({super.key, required this.id});
  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  final me = FirebaseAuth.instance.currentUser!;
  late final g = FirebaseFirestore.instance.collection('groups').doc(widget.id);
  StreamSubscription<Position>? sub;
  Timer? heartbeat;
  Position? pos;
  bool sharing = true, sos = false;
  static const dist = Distance();

  @override
  void initState() {
    super.initState();
    startSharing();
  }

  @override
  void dispose() {
    sub?.cancel();
    heartbeat?.cancel();
    super.dispose();
  }

  Future<void> startSharing() async {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permission is needed to share your position')));
      return;
    }
    // battery-friendly: only update after moving 25 m, plus a 60 s heartbeat while stopped
    sub = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25)).listen((x) {
      pos = x;
      push();
      if (mounted) setState(() {});
    });
    heartbeat = Timer.periodic(const Duration(seconds: 60), (_) => push());
  }

  Future<void> push() async {
    if (pos == null || !sharing) return;
    await g.collection('locations').doc(me.uid).set({
      'name': me.displayName ?? 'Rider', 'lat': pos!.latitude, 'lng': pos!.longitude,
      'speed': pos!.speed, 't': FieldValue.serverTimestamp(), 'sos': sos,
    });
  }

  Future<void> toggleSharing() async {
    sharing = !sharing;
    if (!sharing) await g.collection('locations').doc(me.uid).delete(); else await push();
    setState(() {});
  }

  String km(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext c) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: g.snapshots(),
        builder: (c, gs) {
          final gd = gs.data?.data();
          if (gd == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          final leader = gd['leader'] == me.uid;
          final GeoPoint? d = gd['dest'];
          final dest = d == null ? null : LatLng(d.latitude, d.longitude);
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: g.collection('locations').snapshots(),
            builder: (c, ls) {
              final now = DateTime.now();
              final members = <Map<String, dynamic>>[];
              for (final x in ls.data?.docs ?? []) {
                final m = x.data();
                final ll = LatLng(m['lat'], m['lng']);
                final age = now.difference((m['t'] as Timestamp?)?.toDate() ?? now); // never show stale data as live
                final arrived = dest != null && dist(ll, dest) < 50;
                m['ll'] = ll; m['age'] = age; m['uid'] = x.id;
                m['status'] = age.inMinutes >= 3 ? 'Location unavailable' : arrived ? 'Arrived' : (m['speed'] ?? 0) > 1.5 ? 'Moving' : 'Stopped';
                m['toMe'] = pos == null ? null : dist(LatLng(pos!.latitude, pos!.longitude), ll);
                members.add(m);
              }
              final sosList = members.where((m) => m['sos'] == true).toList();
              final far = members.where((m) => m['uid'] != me.uid && m['status'] != 'Location unavailable' && (m['toMe'] ?? 0) > 2000).toList();
              return Scaffold(
                appBar: AppBar(title: Text(gd['name']), actions: [
                  IconButton(
                    tooltip: 'Copy invite code',
                    icon: const Icon(Icons.qr_code),
                    onPressed: () { Clipboard.setData(ClipboardData(text: gd['code'])); ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Code ${gd['code']} copied'))); },
                  ),
                  IconButton(tooltip: sharing ? 'Stop sharing' : 'Start sharing', icon: Icon(sharing ? Icons.location_on : Icons.location_off), onPressed: toggleSharing),
                ]),
                body: Stack(children: [
                  FlutterMap(
                    options: MapOptions(
                      initialCenter: dest ?? (pos != null ? LatLng(pos!.latitude, pos!.longitude) : const LatLng(10.72, 122.56)),
                      initialZoom: 14,
                      onLongPress: (_, ll) { if (leader) g.update({'dest': GeoPoint(ll.latitude, ll.longitude)}); },
                    ),
                    children: [
                      TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.group_rider'),
                      MarkerLayer(markers: [
                        if (dest != null) Marker(point: dest, width: 40, height: 40, child: const Icon(Icons.flag, color: orange, size: 36)),
                        for (final m in members)
                          Marker(
                            point: m['ll'], width: 44, height: 44,
                            child: CircleAvatar(
                              backgroundColor: m['sos'] == true ? Colors.red : m['status'] == 'Location unavailable' ? Colors.grey : blue,
                              child: Text((m['name'] as String).isEmpty ? '?' : (m['name'] as String)[0].toUpperCase(), style: const TextStyle(color: Colors.white)),
                            ),
                          ),
                      ]),
                    ],
                  ),
                  Column(children: [
                    for (final m in sosList) MaterialBanner(backgroundColor: Colors.red, content: Text('EMERGENCY: ${m['name']} needs help!', style: const TextStyle(color: Colors.white)), actions: const [SizedBox()]),
                    for (final m in far) MaterialBanner(backgroundColor: Colors.amber, content: Text('SEPARATION ALERT: ${m['name']} is ${km(m['toMe'])} away'), actions: const [SizedBox()]),
                    if (leader && dest == null) const Card(child: Padding(padding: EdgeInsets.all(8), child: Text('Leader: long-press the map to set the destination'))),
                  ]),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Card(
                      margin: const EdgeInsets.all(8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                          height: 150,
                          child: ListView(children: [
                            for (final m in members)
                              ListTile(
                                dense: true,
                                title: Text('${m['name']}${m['uid'] == me.uid ? ' (you)' : ''}'),
                                subtitle: Text('${m['status']}  •  ${m['toMe'] == null ? '' : '${km(m['toMe'])} from you  •  '}${dest == null ? '' : '${km(dist(m['ll'], dest).toDouble())} to destination  •  '}${m['age'].inMinutes} min ago'),
                              ),
                          ]),
                        ),
                        Row(children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: sos ? Colors.grey : Colors.red),
                                icon: const Icon(Icons.sos),
                                label: Text(sos ? 'Cancel SOS' : 'SOS'),
                                onPressed: () { sos = !sos; push(); setState(() {}); },
                              ),
                            ),
                          ),
                          if (dest != null)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.navigation),
                                  label: const Text('Navigate'),
                                  onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${dest.latitude},${dest.longitude}'), mode: LaunchMode.externalApplication),
                                ),
                              ),
                            ),
                        ]),
                      ]),
                    ),
                  ),
                ]),
              );
            },
          );
        },
      );
}
