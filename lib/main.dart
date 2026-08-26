import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'road_data.dart';

/// يتحكم بوضع الثيم (تلقائي / داكن / فاتح) على مستوى التطبيق كامل
class ThemeController extends ValueNotifier<String> {
  ThemeController() : super('auto'); // auto | dark | light
}

final themeController = ThemeController();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TexasSpeedGuardApp());
}

class TexasSpeedGuardApp extends StatefulWidget {
  const TexasSpeedGuardApp({super.key});

  @override
  State<TexasSpeedGuardApp> createState() => _TexasSpeedGuardAppState();
}

class _TexasSpeedGuardAppState extends State<TexasSpeedGuardApp> {
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _loadThemePref();
    // يعيد فحص الوقت كل دقيقة عشان يبدّل الثيم تلقائياً لو الوضع "auto"
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    themeController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadThemePref() async {
    final prefs = await SharedPreferences.getInstance();
    themeController.value = prefs.getString('themeMode') ?? 'auto';
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  bool _isNightTimeNow() {
    final hour = DateTime.now().hour;
    return hour >= 19 || hour < 6; // 7 مساءً - 6 صباحاً = ليلي
  }

  @override
  Widget build(BuildContext context) {
    bool useDark;
    switch (themeController.value) {
      case 'dark':
        useDark = true;
        break;
      case 'light':
        useDark = false;
        break;
      default: // auto
        useDark = _isNightTimeNow();
    }

    final darkTheme = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF0A0E21),
      primaryColor: const Color(0xFF1D1E33),
    );

    final lightTheme = ThemeData.light().copyWith(
      scaffoldBackgroundColor: const Color(0xFFF2F2F2),
      primaryColor: const Color(0xFFEDEDED),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Texas Speed Guard',
      theme: useDark ? darkTheme : lightTheme,
      home: const SpeedometerScreen(),
    );
  }
}

enum SpeedometerStyle { digital, analogGauge, hud, tilted }

class SpeedometerScreen extends StatefulWidget {
  const SpeedometerScreen({super.key});

  @override
  State<SpeedometerScreen> createState() => _SpeedometerScreenState();
}

class _SpeedometerScreenState extends State<SpeedometerScreen> {
  final FlutterTts _flutterTts = FlutterTts();
  StreamSubscription<Position>? _positionSubscription;
  double _currentSpeedMph = 0.0;

  int? _estimatedSpeedLimit;
  bool _speedLimitConfirmed = false;

  SpeedometerStyle _currentStyle = SpeedometerStyle.digital;
  bool _isMuted = false;

  double _tiltAngleDegrees = 0.0; // زاوية تصحيح الميلان (وضع Tilted)
  int _maxAlertsPerMinute = 4;
  final List<DateTime> _alertTimestamps = [];

  RoadNetwork? _roadNetwork;
  bool _roadDataFailed = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _flutterTts.setLanguage("en-US");
    _loadSettings();
    _loadRoadData();
    _initLocationTracking();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isMuted = prefs.getBool('isMuted') ?? false;
      _tiltAngleDegrees = prefs.getDouble('tiltAngle') ?? 0.0;
      _maxAlertsPerMinute = prefs.getInt('maxAlertsPerMinute') ?? 4;
      final styleIndex = prefs.getInt('styleIndex') ?? 0;
      _currentStyle = SpeedometerStyle.values[
          styleIndex.clamp(0, SpeedometerStyle.values.length - 1)];
    });
  }

  Future<void> _saveSetting(String key, dynamic value)
