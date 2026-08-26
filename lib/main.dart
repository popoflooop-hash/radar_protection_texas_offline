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

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is double) await prefs.setDouble(key, value);
    if (value is int) await prefs.setInt(key, value);
  }

  Future<void> _loadRoadData() async {
    try {
      final network = await loadRoadNetwork();
      if (!mounted) return;
      setState(() {
        _roadNetwork = network;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _roadDataFailed = true;
      });
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _flutterTts.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  void _initLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((Position position) {
      if (!mounted) return;
      double speedMph = (position.speed * 2.23694);
      setState(() {
        _currentSpeedMph = speedMph < 0 ? 0 : speedMph;
        _updateSpeedLimitFromRoad(position.latitude, position.longitude);
        _checkOverspeedWarning(_currentSpeedMph);
      });
    });
  }

  void _updateSpeedLimitFromRoad(double lat, double lng) {
    final network = _roadNetwork;
    if (network == null) return;

    final match = network.findNearest(lat, lng, maxDistanceMeters: 150);

    if (match == null) {
      _estimatedSpeedLimit = null;
      _speedLimitConfirmed = false;
      return;
    }

    _estimatedSpeedLimit = match.speedLimit;
    _speedLimitConfirmed = true;
  }

  /// ينطق تنبيه صوتي بحد أقصى "عدد مرات بالدقيقة" حسب إعدادات المستخدم
  void _checkOverspeedWarning(double speed) {
    final limit = _estimatedSpeedLimit;
    if (limit == null || _isMuted) return;

    bool isOverLimit = speed > limit + 3;
    if (!isOverLimit) return;

    final now = DateTime.now();
    _alertTimestamps.removeWhere(
        (t) => now.difference(t) > const Duration(minutes: 1));

    if (_alertTimestamps.length < _maxAlertsPerMinute) {
      _alertTimestamps.add(now);
      _flutterTts.speak("Speed limit exceeded. Limit is $limit");
    }
  }

  void _toggleStyle() {
    setState(() {
      final values = SpeedometerStyle.values;
      final nextIndex = (_currentStyle.index + 1) % values.length;
      _currentStyle = values[nextIndex];
    });
    _saveSetting('styleIndex', _currentStyle.index);
  }

  void _shareApp() {
    Share.share(
      'Check out Texas Speed Guard — an offline speed limit app for Texas roads!',
      subject: 'Texas Speed Guard',
    );
  }

  void _openSettings() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initialTiltAngle: _tiltAngleDegrees,
          initialMaxAlerts: _maxAlertsPerMinute,
          initialThemeMode: themeController.value,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _tiltAngleDegrees = result['tiltAngle'] as double;
        _maxAlertsPerMinute = result['maxAlertsPerMinute'] as int;
      });
      _saveSetting('tiltAngle', _tiltAngleDegrees);
      _saveSetting('maxAlertsPerMinute', _maxAlertsPerMinute);

      final newThemeMode = result['themeMode'] as String;
      themeController.value = newThemeMode;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('themeMode', newThemeMode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final limit = _estimatedSpeedLimit;
    bool isSpeeding = limit != null && _currentSpeedMph > limit;
    Color alertColor = limit == null
        ? Colors.grey
        : (isSpeeding ? Colors.redAccent : Colors.greenAccent);

    Widget content = Scaffold(
      appBar: AppBar(
        title: const Text('Texas Speed Guard'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareApp,
          ),
          IconButton(
            icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up),
            onPressed: () {
              setState(() => _isMuted = !_isMuted);
              _saveSetting('isMuted', _isMuted);
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (_roadNetwork == null && !_roadDataFailed)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Loading road data...',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          if (_roadDataFailed)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Could not load speed limit data',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _toggleStyle,
                icon: const Icon(Icons.dashboard_customize),
                label: Text(_getStyleName(_currentStyle)),
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: _buildSpeedometerWidget(alertColor),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black, width: 4),
            ),
            child: Column(
              children: [
                const Text('SPEED\nLIMIT',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                Text(
                  limit?.toString() ?? '--',
                  style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 36),
                ),
                if (limit != null)
                  Text(
                    _speedLimitConfirmed ? '(TxDOT official data)' : '',
                    style: const TextStyle(color: Colors.black54, fontSize: 10),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );

    // وضع Tilted: يدوّر الشاشة بزاوية تصحيح حسب ميلان حامل الموبايل
    if (_currentStyle == SpeedometerStyle.tilted) {
      return Transform.rotate(
        angle: -_tiltAngleDegrees * pi / 180,
        child: content,
      );
    }

    // وضع HUD: انعكاس أفقي لزجاج السيارة
    if (_currentStyle == SpeedometerStyle.hud) {
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scale(1.0, -1.0),
        child: content,
      );
    }

    return content;
  }

  String _getStyleName(SpeedometerStyle style) {
    switch (style) {
      case SpeedometerStyle.digital:
        return 'Style: Digital';
      case SpeedometerStyle.analogGauge:
        return 'Style: Analog Gauge';
      case SpeedometerStyle.hud:
        return 'Style: HUD Mirror';
      case SpeedometerStyle.tilted:
        return 'Style: Tilted';
    }
  }

  Widget _buildSpeedometerWidget(Color alertColor) {
    switch (_currentStyle) {
      case SpeedometerStyle.analogGauge:
        return CustomPaint(
          size: const Size(250, 250),
          painter: GaugePainter(speed: _currentSpeedMph, alertColor: alertColor),
        );
      case SpeedometerStyle.hud:
      case SpeedometerStyle.tilted:
      case SpeedometerStyle.digital:
      default:
        return Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: alertColor, width: 8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _currentSpeedMph.toStringAsFixed(0),
                style: TextStyle(
                    fontSize: 80, fontWeight: FontWeight.bold, color: alertColor),
              ),
              const Text('MPH', style: TextStyle(fontSize: 20, color: Colors.grey)),
            ],
          ),
        );
    }
  }
}

class GaugePainter extends CustomPainter {
  final double speed;
  final Color alertColor;

  GaugePainter({required this.speed, required this.alertColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final trackPaint = Paint()
      ..color = Colors.grey.shade800
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14;

    final progressPaint = Paint()
      ..color = alertColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 10),
      pi * 0.75,
      pi * 1.5,
      false,
      trackPaint,
    );

    double sweepAngle = (speed / 120).clamp(0.0, 1.0) * (pi * 1.5);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 10),
      pi * 0.75,
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// شاشة الإعدادات
class SettingsScreen extends StatefulWidget {
  final double initialTiltAngle;
  final int initialMaxAlerts;
  final String initialThemeMode;

  const SettingsScreen({
    super.key,
    required this.initialTiltAngle,
    required this.initialMaxAlerts,
    required this.initialThemeMode,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _tiltAngle;
  late int _maxAlerts;
  late String _themeMode;

  @override
  void initState() {
    super.initState();
    _tiltAngle = widget.initialTiltAngle;
    _maxAlerts = widget.initialMaxAlerts;
    _themeMode = widget.initialThemeMode;
  }

  void _returnResult() {
    Navigator.of(context).pop({
      'tiltAngle': _tiltAngle,
      'maxAlertsPerMinute': _maxAlerts,
      'themeMode': _themeMode,
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        _returnResult();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _returnResult,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Theme',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
                ButtonSegment(value: 'light', label: Text('Light')),
              ],
              selected: {_themeMode},
              onSelectionChanged: (s) {
                setState(() => _themeMode = s.first);
              },
            ),
            const SizedBox(height: 8),
            const Text(
              'Auto switches to Dark from 7 PM to 6 AM (Texas time) automatically.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const Divider(height: 32),
            const Text('Mount Tilt Angle',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text('${_tiltAngle.round()}°'),
            Slider(
              value: _tiltAngle,
              min: -60,
              max: 60,
              divisions: 120,
              label: '${_tiltAngle.round()}°',
              onChanged: (v) => setState(() => _tiltAngle = v),
            ),
            const Text(
              'Used only in "Tilted" display style, to correct for how your phone mount is angled.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const Divider(height: 32),
            const Text('Max Voice Alerts Per Minute',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text('$_maxAlerts alert(s) / minute'),
            Slider(
              value: _maxAlerts.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$_maxAlerts',
              onChanged: (v) => setState(() => _maxAlerts = v.round()),
            ),
          ],
        ),
      ),
    );
  }
}
