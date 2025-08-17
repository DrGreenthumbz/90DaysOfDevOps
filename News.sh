#!/usr/bin/env sh
# build_now.sh — one-shot create+build BizNews APK (working sentiment+tag filters with persistence)
# - Prompts ONLY for App display name
# - API fixed to http://192.168.1.10:30880
# - Search (title/summary/tags), sentiment filter, multi-tag filter, persisted via SharedPreferences
# - TTS "Listen", Explore/Alerts/Profile pages
# - APK output: ./releases/<slug>_release_<timestamp>.apk + ./releases/latest.apk

set -eu

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ts(){ date +%Y%m%d%H%M%S; }
slug(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/_+/_/g; s/^_|_$//g'; }
rand8(){ tr -dc 'a-z' </dev/urandom | head -c 8; }

API_BASE="http://192.168.1.10:30880"
ALT_API_BASE=""

command -v flutter >/dev/null 2>&1 || die "flutter not found in PATH"
command -v java    >/dev/null 2>&1 || die "java (JDK) not found in PATH"

printf 'App display name (e.g., BizNews): '
IFS= read -r APP_NAME
[ -n "$APP_NAME" ] || APP_NAME="BizNews"

TS="$(ts)"
SEG="$(slug "$APP_NAME")"; case "$SEG" in [a-z]*) : ;; *) SEG="a$SEG" ;; esac
ORG="com.$(rand8).news"
APP_ID="${ORG}.${SEG}.t${TS}"
PROJ="${SEG}_${TS}"
PROJ_DIR="$PWD/$PROJ"

printf '\nPlan:\n  API_BASE      : %s\n  App Name      : %s\n  Org Package   : %s\n  ApplicationId : %s\n  Project Dir   : %s\n\n' \
  "$API_BASE" "$APP_NAME" "$ORG" "$APP_ID" "$PROJ_DIR"

echo "• Creating Flutter skeleton…"
flutter create --org "$ORG" --project-name "$PROJ" "$PROJ_DIR"

cd "$PROJ_DIR"
mkdir -p ./logs ./releases

# -------- pubspec --------
cat > pubspec.yaml <<'YAML'
name: biznews_app
description: Business news client with TTS, search, sentiment & tag filters
publish_to: "none"
version: 1.0.0+1

environment:
  sdk: ">=3.3.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  dio: ^5.5.0
  shared_preferences: ^2.3.2
  flutter_tts: ^3.8.0
  url_launcher: ^6.3.0
  intl: ^0.19.0
  google_fonts: ^6.2.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
YAML

# -------- Android v2 embedding + cleartext --------
mkdir -p android/app/src/main/res/xml
cat > android/app/src/main/AndroidManifest.xml <<MANI
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="${APP_ID}">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>

    <application
        android:label="${APP_NAME}"
        android:icon="@mipmap/ic_launcher"
        android:usesCleartextTraffic="true"
        android:networkSecurityConfig="@xml/network_security_config">

        <activity
            android:name="io.flutter.embedding.android.FlutterActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
            <meta-data android:name="io.flutter.embedding.android.NormalTheme" android:resource="@style/NormalTheme"/>
        </activity>

        <meta-data android:name="flutterEmbedding" android:value="2"/>
    </application>
</manifest>
MANI

cat > android/app/src/main/res/xml/network_security_config.xml <<'XML'
<network-security-config>
  <base-config cleartextTrafficPermitted="true">
    <trust-anchors><certificates src="system" /></trust-anchors>
  </base-config>
</network-security-config>
XML

cat >> android/gradle.properties <<'PROPS'
org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8
org.gradle.daemon=false
android.useAndroidX=true
android.enableJetifier=true
PROPS
sed -i -E "s/applicationId \"[^\"]+\"/applicationId \"${APP_ID}\"/" android/app/build.gradle || true
sed -i -E "s/^(\s*namespace\s+).*/\1'${APP_ID}'/" android/app/build.gradle || true
sed -i -E "s/applicationId\s*=\s*\"[^\"]+\"/applicationId = \"${APP_ID}\"/" android/app/build.gradle.kts 2>/dev/null || true
sed -i -E "s/^(\s*namespace\s*=\s*).*/\1\"${APP_ID}\"/" android/app/build.gradle.kts 2>/dev/null || true
rm -rf android/app/src/main/kotlin android/app/src/main/java || true

# -------- lib code --------
mkdir -p lib/models lib/services lib/screens lib/widgets

# models/article.dart
cat > lib/models/article.dart <<'DART'
class Article {
  final String id, title, summary, sentiment, source, publishedAt;
  final String? url;
  final List<String> tags;
  Article({
    required this.id,
    required this.title,
    required this.summary,
    required this.sentiment,
    required this.source,
    required this.publishedAt,
    required this.tags,
    this.url,
  });
  factory Article.fromJson(Map<String, dynamic> j) => Article(
        id: j['id'] ?? '',
        title: j['rewritten_title'] ?? '',
        summary: j['rewritten_summary'] ?? '',
        sentiment: j['sentiment'] ?? 'neutral',
        source: j['source'] ?? '-',
        publishedAt: j['published_at'] ?? '',
        url: j['url'],
        tags: (j['tags'] as List? ?? const []).map((e) => '$e').toList(),
      );
}
DART

# services/api.dart
cat > lib/services/api.dart <<'DART'
import 'package:dio/dio.dart';
import '../models/article.dart';

class FeedResult {
  final List<Article> items;
  final List<String> allTags;
  FeedResult(this.items, this.allTags);
}

class ApiService {
  final Dio _dio;
  final String primary;
  final String? fallback;
  ApiService(this.primary, this.fallback)
      : _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20)));

  Future<FeedResult> feed({
    String? sentiment,
    List<String>? tags,
    int page = 1,
    int size = 50,
  }) async {
    final must = <String, dynamic>{};
    if (sentiment != null && sentiment != 'any') {
      must['sentiment'] = [sentiment];
    }
    if (tags != null && tags.isNotEmpty) {
      must['tags'] = tags;
    }
    final body = <String, dynamic>{
      'query': { if (must.isNotEmpty) 'must': must },
      'page': page,
      'size': size,
    };

    Future<FeedResult> run(String base) async {
      final r = await _dio.post('$base/feeds/', data: body);
      final list = (r.data['items'] as List).map((e) => Article.fromJson(e)).toList();
      // Build tag universe locally too (in case backend ignores filters)
      final set = <String>{};
      for (final a in list) { set.addAll(a.tags); }
      final allTags = set.toList()..sort();
      return FeedResult(list, allTags);
    }

    try { return await run(primary); }
    catch (_) {
      if (fallback != null && fallback!.isNotEmpty) return await run(fallback!);
      rethrow;
    }
  }
}
DART

# services/tts.dart
cat > lib/services/tts.dart <<'DART'
import 'package:flutter_tts/flutter_tts.dart';
class Tts{
  static final _tts = FlutterTts();
  static bool _inited=false;
  static Future<void> init() async { if(_inited) return; await _tts.setSpeechRate(0.95); _inited=true; }
  static Future<void> speak(String text) async { await init(); await _tts.stop(); await _tts.speak(text); }
  static Future<void> stop()=>_tts.stop();
}
DART

# services/storage.dart (adds getString/setString)
cat > lib/services/storage.dart <<'DART'
import 'package:shared_preferences/shared_preferences.dart';
class Store{
  static Future<List<String>> getList(String k) async{ final sp=await SharedPreferences.getInstance(); return sp.getStringList(k)??<String>[]; }
  static Future<void> setList(String k, List<String> v) async{ final sp=await SharedPreferences.getInstance(); await sp.setStringList(k,v); }
  static Future<bool> getBool(String k, {bool def=false}) async { final sp=await SharedPreferences.getInstance(); return sp.getBool(k)??def; }
  static Future<void> setBool(String k, bool v) async { final sp=await SharedPreferences.getInstance(); await sp.setBool(k,v); }
  static Future<String> getString(String k, {String def=''}) async { final sp=await SharedPreferences.getInstance(); return sp.getString(k)??def; }
  static Future<void> setString(String k, String v) async { final sp=await SharedPreferences.getInstance(); await sp.setString(k,v); }
}
DART

# widgets/article_card.dart
cat > lib/widgets/article_card.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

Color _sc(String s, BuildContext c){
  switch (s){
    case 'positive': return Colors.green;
    case 'negative': return Colors.red;
    default: return Theme.of(c).colorScheme.outline;
  }
}

class ArticleCard extends StatelessWidget{
  final String title, summary, sentiment, source, publishedAt;
  final List<String> tags;
  final String? url;
  final VoidCallback? onListen;
  const ArticleCard({
    super.key,
    required this.title,
    required this.summary,
    required this.sentiment,
    required this.source,
    required this.publishedAt,
    required this.tags,
    this.url,
    this.onListen
  });

  @override Widget build(BuildContext context){
    final dt = DateTime.tryParse(publishedAt)?.toLocal();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal:12, vertical:6),
      elevation:2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
          Row(children:[
            Container(
              padding: const EdgeInsets.symmetric(horizontal:10, vertical:4),
              decoration: BoxDecoration(
                color: _sc(sentiment, context).withOpacity(0.12),
                borderRadius: BorderRadius.circular(999)
              ),
              child: Text(sentiment.toUpperCase(),
                style: TextStyle(color:_sc(sentiment, context), fontWeight: FontWeight.w800, fontSize:11)),
            ),
            const SizedBox(width:10),
            Text(source, style: Theme.of(context).textTheme.labelMedium),
            const Spacer(),
            Text(dt==null? '' : DateFormat('MMM d, HH:mm').format(dt),
              style: Theme.of(context).textTheme.labelSmall),
          ]),
          const SizedBox(height:10),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height:6),
          Text(summary, maxLines:4, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height:10),
          Wrap(spacing:6, runSpacing:-6, children: [
            for (final t in tags.take(8)) Chip(label: Text(t)),
          ]),
          const SizedBox(height:8),
          Row(children: [
            if (onListen!=null)
              TextButton.icon(onPressed:onListen, icon: const Icon(Icons.volume_up_rounded), label: const Text('Listen')),
            const Spacer(),
            if (url!=null && url!.isNotEmpty)
              TextButton.icon(onPressed: ()=>launchUrl(Uri.parse(url!)), icon: const Icon(Icons.open_in_new), label: const Text('Source')),
          ])
        ]),
      ),
    );
  }
}
DART

# screens/feed.dart — FILTERS WORK + PERSIST
cat > lib/screens/feed.dart <<'DART'
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/tts.dart';
import '../services/storage.dart';
import '../models/article.dart';
import '../widgets/article_card.dart';

class FeedScreen extends StatefulWidget{
  final ApiService api;
  const FeedScreen({super.key, required this.api});
  @override State<FeedScreen> createState()=>_S();
}

class _S extends State<FeedScreen>{
  final _search=TextEditingController();
  String _sentiment='any';
  final Set<String> _selectedTags={};
  List<String> _allTags=[];
  late Future<List<Article>> _future;
  List<Article> _cache=[];
  bool _loading=false;

  @override void initState(){ super.initState(); _future=_load(initial:true); }

  Future<void> _loadPrefs() async {
    final s = await Store.getString('filter_sentiment', def: 'any');
    final tags = await Store.getList('filter_tags');
    setState(() {
      _sentiment = s.isEmpty ? 'any' : s;
      _selectedTags..clear()..addAll(tags);
    });
  }

  Future<void> _savePrefs() async {
    await Store.setString('filter_sentiment', _sentiment);
    await Store.setList('filter_tags', _selectedTags.toList());
  }

  Future<List<Article>> _load({bool initial=false}) async{
    setState(() { _loading=true; });
    if (initial) { await _loadPrefs(); }
    // Fetch WITHOUT relying on backend filtering; we filter locally.
    final res=await widget.api.feed();
    final all = res.items;
    final tagSet = <String>{};
    for (final a in all) { tagSet.addAll(a.tags); }
    setState(() {
      _cache=all;
      _allTags=tagSet.toList()..sort();
      _loading=false;
    });
    return all;
  }

  bool _matchesFilters(Article a){
    if (_sentiment!='any' && a.sentiment != _sentiment) return false;
    if (_selectedTags.isNotEmpty){
      // require ALL selected tags to be present in article
      for (final t in _selectedTags){
        if (!a.tags.contains(t)) return false;
      }
    }
    return true;
    }

  Future<void> _openFilterSheet() async{
    String tmpSent=_sentiment; final tmpTags={..._selectedTags};
    final applied = await showModalBottomSheet<bool>(
      context: context, showDragHandle: true, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder:(ctx){
        return DraggableScrollableSheet(
          expand:false, initialChildSize:0.6, maxChildSize:0.9, minChildSize:0.4,
          builder:(ctx, controller){
            return StatefulBuilder(builder:(ctx,set){
              return Padding(padding: const EdgeInsets.fromLTRB(16,8,16,16), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children:[
                  const Text('Filters', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                  const SizedBox(height:10),
                  Wrap(spacing:8, children:[
                    for (final s in ['any','positive','neutral','negative'])
                      ChoiceChip(label: Text(s), selected: tmpSent==s, onSelected:(_)=> set(() => tmpSent=s)),
                  ]),
                  const SizedBox(height:12),
                  const Text('Tags'), const SizedBox(height:6),
                  Expanded(child: SingleChildScrollView(controller: controller, child: Wrap(spacing:8, runSpacing:8, children:[
                    for (final t in _allTags)
                      FilterChip(label: Text(t), selected: tmpTags.contains(t), onSelected:(v)=> set(() => v ? tmpTags.add(t) : tmpTags.remove(t))),
                  ]))),
                  const SizedBox(height:10),
                  Row(children:[
                    TextButton(onPressed:(){ tmpTags.clear(); tmpSent='any'; set((){}); }, child: const Text('Clear')),
                    const Spacer(),
                    TextButton(onPressed: ()=> Navigator.pop(ctx,false), child: const Text('Cancel')),
                    const SizedBox(width:6),
                    FilledButton.icon(onPressed: ()=> Navigator.pop(ctx,true), icon: const Icon(Icons.check), label: const Text('Apply')),
                  ])
                ],
              ));
            });
          },
        );
      }
    );
    if (applied==true){
      setState(() {
        _sentiment=tmpSent;
        _selectedTags..clear()..addAll(tmpTags);
      });
      await _savePrefs();
      // No need to refetch; we filter locally. If you want to refresh tags universe from server, call _future=_load();
      setState((){}); // trigger rebuild
    }
  }

  @override Widget build(BuildContext c){
    return Column(children:[
      Padding(padding:const EdgeInsets.fromLTRB(12,8,12,6), child: Row(children:[
        Expanded(child: TextField(controller:_search, onChanged:(_)=>setState((){}),
          decoration:const InputDecoration(
            hintText:'Search in titles, summaries, tags…',
            prefixIcon:Icon(Icons.search),
            border:OutlineInputBorder(borderRadius:BorderRadius.all(Radius.circular(16))),
            contentPadding:EdgeInsets.symmetric(horizontal:12, vertical:10),
          ),
        )),
        const SizedBox(width:8),
        IconButton.outlined(onPressed:_openFilterSheet, icon:const Icon(Icons.filter_alt_rounded)),
      ])),
      if (_sentiment!='any' || _selectedTags.isNotEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal:12), child: Wrap(spacing:6, runSpacing:-6, children:[
          if (_sentiment!='any')
            InputChip(label: Text('sentiment: $_sentiment'), onDeleted:() async { setState(() { _sentiment='any'; }); await _savePrefs(); }),
          for (final t in _selectedTags)
            InputChip(label: Text(t), onDeleted:() async { setState(() { _selectedTags.remove(t); }); await _savePrefs(); }),
          TextButton(onPressed:() async {
            setState(() {
              _sentiment='any';
              _selectedTags.clear();
            });
            await _savePrefs();
          }, child: const Text('Clear all')),
        ])),
      const SizedBox(height:6),
      Expanded(child: RefreshIndicator(onRefresh:()=>_load(), child: FutureBuilder<List<Article>>(future:_future, builder:(_,snap){
        final loading=_loading || snap.connectionState!=ConnectionState.done;
        final err=snap.hasError? snap.error : null;
        final items=(snap.data ?? _cache);

        // Apply filters + search locally
        final q=_search.text.trim().toLowerCase();
        final filtered = items.where((a){
          if (!_matchesFilters(a)) return false;
          if (q.isEmpty) return true;
          final hay=(a.title+' '+a.summary+' '+a.tags.join(' ')).toLowerCase();
          return hay.contains(q);
        }).toList();

        if (loading && _cache.isEmpty) return const Center(child:CircularProgressIndicator());
        if (err!=null && _cache.isEmpty) return Center(child: Text('Error: $err'));
        if (filtered.isEmpty) return const Center(child: Text('No items found.'));

        return ListView.builder(physics: const AlwaysScrollableScrollPhysics(), itemCount: filtered.length, itemBuilder:(_,i){
          final it=filtered[i];
          return ArticleCard(
            title: it.title,
            summary: it.summary,
            sentiment: it.sentiment,
            source: it.source,
            publishedAt: it.publishedAt,
            tags: it.tags,
            url: it.url,
            onListen: ()=> Tts.speak('${it.title}. ${it.summary}'),
          );
        });
      }))),
    ]);
  }
}
DART

# screens/explore.dart
cat > lib/screens/explore.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExploreScreen extends StatefulWidget{ const ExploreScreen({super.key}); @override State<ExploreScreen> createState()=>_S(); }
class _S extends State<ExploreScreen>{
  final Set<String> _topics={};
  final moods=['long-term investor','energy-only','robotics-only','macro-news'];
  String? _quickProfile;
  final presetTopics=['green-energy','ai','robotics','kitchen-robotics','banking','chips','autos','retail','cloud','space','gold','aluminium','lasers','military','gps'];

  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async{
    final sp=await SharedPreferences.getInstance();
    setState(() { _topics.addAll(sp.getStringList('topics')??[]); _quickProfile=sp.getString('profile'); });
  }
  Future<void> _save() async{
    final sp=await SharedPreferences.getInstance();
    await sp.setStringList('topics', _topics.toList());
    if(_quickProfile!=null) await sp.setString('profile', _quickProfile!);
    if(!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  @override Widget build(BuildContext c){
    return Padding(padding: const EdgeInsets.all(16), child: ListView(children: [
      const Text('Quick Profiles', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)), const SizedBox(height:8),
      Wrap(spacing:8, runSpacing:8, children:[
        for (final m in moods)
          ChoiceChip(label: Text(m), selected: _quickProfile==m, onSelected: (_){ setState(() => _quickProfile=m); })
      ]),
      const SizedBox(height:18),
      const Text('Interests', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)), const SizedBox(height:8),
      Wrap(spacing:8, runSpacing:8, children:[
        for (final t in presetTopics)
          FilterChip(label: Text(t), selected: _topics.contains(t), onSelected: (v){ setState(() => v ? _topics.add(t) : _topics.remove(t)); })
      ]),
      const SizedBox(height:24),
      FilledButton.icon(onPressed:_save, icon: const Icon(Icons.save_rounded), label: const Text('Save preferences')),
    ]));
  }
}
DART

# screens/alerts.dart
cat > lib/screens/alerts.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AlertsScreen extends StatefulWidget{ const AlertsScreen({super.key}); @override State<AlertsScreen> createState()=>_S(); }
class _S extends State<AlertsScreen>{
  final List<String> _alerts=[]; final _ctrl=TextEditingController();
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async { final sp=await SharedPreferences.getInstance(); setState(() => _alerts.addAll(sp.getStringList('alerts')??[])); }
  Future<void> _save() async { final sp=await SharedPreferences.getInstance(); await sp.setStringList('alerts', _alerts); }
  void _add(){ final t=_ctrl.text.trim(); if(t.isEmpty)return; setState(() => _alerts.add(t)); _ctrl.clear(); _save(); }
  void _del(int i){ setState(() => _alerts.removeAt(i)); _save(); }
  @override Widget build(BuildContext c){
    return Padding(padding: const EdgeInsets.all(16), child: Column(children:[
      Row(children:[ Expanded(child: TextField(controller:_ctrl, decoration: const InputDecoration(hintText:'e.g. CPI release 08:00', border: OutlineInputBorder()))),
        const SizedBox(width:8), FilledButton(onPressed:_add, child: const Icon(Icons.add)) ]),
      const SizedBox(height:12),
      Expanded(child: _alerts.isEmpty? const Center(child: Text('No alerts yet')) : ListView.separated(
        itemCount:_alerts.length, separatorBuilder:(_, __)=> const Divider(height:1),
        itemBuilder:(_,i)=> ListTile(title: Text(_alerts[i]), trailing: IconButton(onPressed: ()=>_del(i), icon: const Icon(Icons.delete_outline))) )),
    ]));
  }
}
DART

# screens/profile.dart
cat > lib/screens/profile.dart <<'DART'
import 'package:flutter/material.dart';
import '../services/storage.dart';

class ProfileScreen extends StatefulWidget{
  final String primary; final String? fallback;
  const ProfileScreen({super.key, required this.primary, this.fallback});
  @override State<ProfileScreen> createState()=>_S();
}
class _S extends State<ProfileScreen>{
  bool highContrast=false, blind=false;
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async {
    highContrast = await Store.getBool('theme_high_contrast');
    blind = await Store.getBool('a11y_blind');
    if(mounted) setState((){});
  }
  Future<void> _save() async {
    await Store.setBool('theme_high_contrast', highContrast);
    await Store.setBool('a11y_blind', blind);
    if(!mounted)return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Saved')));
  }
  @override Widget build(BuildContext c){
    return ListView(children:[
      ListTile(title: const Text('API (primary)'), subtitle: Text(widget.primary)),
      if(widget.fallback!=null && widget.fallback!.isNotEmpty)
        ListTile(title: const Text('API (fallback)'), subtitle: Text(widget.fallback!)),
      const Divider(),
      SwitchListTile(value: highContrast, onChanged:(v)=>setState(() => highContrast=v), title: const Text('High contrast theme')),
      SwitchListTile(value: blind, onChanged:(v)=>setState(() => blind=v), title: const Text('Blind assistance (TTS default)')),
      Padding(padding: const EdgeInsets.all(16), child: FilledButton.icon(onPressed:_save, icon: const Icon(Icons.save), label: const Text('Save settings'))),
      const SizedBox(height:24),
      const Padding(padding: EdgeInsets.symmetric(horizontal:16), child: Text('About', style: TextStyle(fontWeight: FontWeight.w700))),
      const ListTile(title: Text('BizNews Prototype'), subtitle: Text('Search, sentiment & tag filters (persisted), TTS, profiles, alerts.')),
    ]);
  }
}
DART

# app.dart
cat > lib/app.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/feed.dart';
import 'screens/explore.dart';
import 'screens/alerts.dart';
import 'screens/profile.dart';
import 'services/api.dart';

class AppShell extends StatefulWidget{
  final String primary; final String? fallback; final String appName;
  const AppShell({super.key, required this.primary, this.fallback, required this.appName});
  @override State<AppShell> createState()=>_S();
}
class _S extends State<AppShell>{
  int idx=0; late final ApiService api;
  @override void initState(){ super.initState(); api=ApiService(widget.primary, widget.fallback); }
  @override Widget build(BuildContext context){
    final pages=[ FeedScreen(api: api), const ExploreScreen(), const AlertsScreen(), ProfileScreen(primary: widget.primary, fallback: widget.fallback) ];
    final theme=ThemeData(useMaterial3:true, colorSchemeSeed: Colors.indigo, textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme));
    return MaterialApp(title: widget.appName, theme: theme, home:Scaffold(
      appBar: AppBar(title: Text(widget.appName)),
      body: pages[idx],
      bottomNavigationBar: NavigationBar(selectedIndex: idx, onDestinationSelected:(i)=>setState(() => idx=i), destinations: const [
        NavigationDestination(icon: Icon(Icons.article_outlined), selectedIcon: Icon(Icons.article), label:'Feed'),
        NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label:'Explore'),
        NavigationDestination(icon: Icon(Icons.alarm_outlined), selectedIcon: Icon(Icons.alarm), label:'Alerts'),
        NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label:'Profile'),
      ]),
    ));
  }
}
DART

# main.dart
cat > lib/main.dart <<'DART'
import 'package:flutter/material.dart';
import 'app.dart';
const String kPrimary = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8080');
const String kFallback = String.fromEnvironment('ALT_API_BASE', defaultValue: '');
const String kAppName = String.fromEnvironment('APP_NAME', defaultValue: 'BizNews');
void main()=> runApp(AppShell(primary: kPrimary, fallback: kFallback.isEmpty?null:kFallback, appName: kAppName));
DART

# -------- build --------
echo "• Toolchain check"
flutter --version
yes | flutter doctor --android-licenses || true
flutter doctor -v || true
if command -v sdkmanager >/dev/null 2>&1; then
  echo "• Ensuring Android SDK components (best-effort)"
  yes | sdkmanager --licenses || true
  sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" || true
fi

echo "• flutter pub get"
flutter pub get 2>&1 | tee ./logs/pubget.log

echo "• flutter build apk --release  (this is the long step)"
flutter build apk --release \
  --dart-define=API_BASE="$API_BASE" \
  --dart-define=ALT_API_BASE="$ALT_API_BASE" \
  --dart-define=APP_NAME="$APP_NAME" 2>&1 | tee ./logs/build.log

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || die "APK not found at $APK (see ./logs/build.log)"

OUT_TS="$(ts)"
OUT_SEG="$(slug "$APP_NAME")"
OUT="./releases/${OUT_SEG}_release_${OUT_TS}.apk"
cp -f "$APK" "$OUT"
ln -sf "$(basename "$OUT")" "./releases/latest.apk"

echo
echo "✅ Build complete"
echo "APK : $OUT"
echo "Logs:"
echo "  pubget → ./logs/pubget.log"
echo "  build  → ./logs/build.log"
echo
