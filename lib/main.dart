import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'road_data.dart';

const Color kGold = Color(0xFFD4AF37);

class ThemeController extends ValueNotifier<String> {
  ThemeController() : super('auto'); // auto | dark | light
}

class AccentColorController extends ValueNotifier<Color> {
  AccentColorController() : super(kGold);
}

final themeController = ThemeController();
final accentColorController = AccentColorController();

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
    _loadPrefs();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    themeController.addListener(_onChange);
    accentColorController.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    themeController.value = prefs.getString('themeMode') ?? 'auto';
    final savedColor = prefs.getInt('accentColor');
    if (savedColor != null) {
      accentColorController.value = Color(savedColor);
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    themeController.removeListener(_onChange);
    accentColorController.removeListener(_onChange);
    super.dispose();
  }

  bool _isNightTimeNow() {
    final hour = DateTime.now().hour;
    return hour >= 19 || hour < 6;
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
      default:
        useDark = _isNightTimeNow();
    }

    final darkTheme = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: Colors.black,
      primaryColor: Colors.black,
      appBarTheme: const AppBarTheme(backgroundColor: Colors.black),
    );

    final lightTheme = ThemeData.light().copyWith(
      scaffoldBackgroundColor: const Color(0xFFF4F1E8),
      primaryColor: const Color(0xFFF4F1E8),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF4F1E8)),
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
  bool _isTracking = false;

  double _tiltAngleDegrees = 0.0;
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

  Future<void> _startTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Please turn on Location (GPS) in your phone settings.'),
          ),
        );
      }
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Location permission denied. Please allow it to use tracking.'),
            ),
          );
        }
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Location permission is permanently denied. Enable it manually from your phone Settings > Apps > Texas Speed Guard > Permissions.'),
          ),
        );
      }
      return;
    }

    setState(() => _isTracking = true);

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

  void _stopTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    setState(() {
      _isTracking = false;
      _currentSpeedMph = 0;
      _estimatedSpeedLimit = null;
      _speedLimitConfirmed = false;
      _alertTimestamps.clear();
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

  void _openColorPicker() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ColorPickerScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: accentColorController,
      builder: (context, accent, _) {
        final limit = _estimatedSpeedLimit;
        bool isSpeeding = limit != null && _currentSpeedMph > limit;
        Color statusColor = limit == null
            ? Colors.grey
            : (isSpeeding ? Colors.redAccent : Colors.greenAccent);

        Widget content = Scaffold(
          appBar: AppBar(
            title: Text('Texas Speed Guard', style: TextStyle(color: accent)),
            centerTitle: true,
            iconTheme: IconThemeData(color: accent),
            actions: [
              IconButton(
                icon: const Icon(Icons.share),
                color: accent,
                onPressed: _shareApp,
              ),
              IconButton(
                icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up),
                color: accent,
                onPressed: () {
                  setState(() => _isMuted = !_isMuted);
                  _saveSetting('isMuted', _isMuted);
                },
              ),
              IconButton(
                icon: const Icon(Icons.edit),
                color: accent,
                onPressed: _openColorPicker,
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                color: accent,
                onPressed: _openSettings,
              ),
            ],
          ),
          body: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_roadNetwork == null && !_roadDataFailed)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Loading road data...',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              if (_roadDataFailed)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Could not load speed limit data',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isTracking ? _stopTracking : _startTracking,
                    icon: Icon(
                      _isTracking ? Icons.stop : Icons.play_arrow,
                      color: accent,
                    ),
                    label: Text(
                      _isTracking ? 'Stop tracking' : 'Start tracking',
                      style: TextStyle(color: accent),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _toggleStyle,
                    icon: const Icon(Icons.dashboard_customize),
                    label: Text(_getStyleName(_currentStyle)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: _buildSpeedometerWidget(accent, statusColor),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: accent, width: 1.5),
                ),
                child: Column(
                  children: [
                    Text('SPEED LIMIT',
                        style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1,
                            fontSize: 11)),
                    Text(
                      limit?.toString() ?? '--',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          fontSize: 30),
                    ),
                    Text(
                      _speedLimitConfirmed ? 'TxDOT official data' : '',
                      style: const TextStyle(color: Colors.grey, fontSize: 9),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );

        if (_currentStyle == SpeedometerStyle.tilted) {
          return Transform.rotate(
            angle: -_tiltAngleDegrees * pi / 180,
            child: content,
          );
        }

        if (_currentStyle == SpeedometerStyle.hud) {
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scale(1.0, -1.0),
            child: content,
          );
        }

        return content;
      },
    );
  }

  String _getStyleName(SpeedometerStyle style) {
    switch (style) {
      case SpeedometerStyle.digital:
        return 'Style: Digital';
      case SpeedometerStyle.analogGauge:
        return 'Style: Gauge';
      case SpeedometerStyle.hud:
        return 'Style: HUD Mirror';
      case SpeedometerStyle.tilted:
        return 'Style: Tilted';
    }
  }

  Widget _buildSpeedometerWidget(Color accent, Color statusColor) {
    if (_currentStyle == SpeedometerStyle.analogGauge) {
      return CustomPaint(
        size: const Size(240, 240),
        painter: RealGaugePainter(
          speed: _currentSpeedMph,
          accentColor: accent,
          needleColor: statusColor,
        ),
      );
    }

    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: statusColor, width: 8),
        color: const Color(0xFF0A0A0A),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _currentSpeedMph.toStringAsFixed(0),
            style: TextStyle(
                fontSize: 78, fontWeight: FontWeight.w500, color: statusColor),
          ),
          const Text('MPH', style: TextStyle(fontSize: 18, color: Colors.grey)),
        ],
      ),
    );
  }
}

class RealGaugePainter extends CustomPainter {
  final double speed;
  final Color accentColor;
  final Color needleColor;
  static const double maxSpeed = 140;
  static const double startAngle = 135 * pi / 180;
  static const double sweepTotal = 270 * pi / 180;

  RealGaugePainter({
    required this.speed,
    required this.accentColor,
    required this.needleColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final ringPaint = Paint()
      ..color = const Color(0xFF0A0A0A)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, ringPaint);

    final ringBorder = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius - 2, ringBorder);

    for (double v = 0; v <= maxSpeed; v += 10) {
      final angle = startAngle + (v / maxSpeed) * sweepTotal;
      final isMajor = (v.toInt() % 20 == 0);
      final outerR = radius - 8;
      final innerR = isMajor ? radius - 26 : radius - 20;

      final p1 = Offset(center.dx + outerR * cos(angle),
          center.dy + outerR * sin(angle));
      final p2 = Offset(center.dx + innerR * cos(angle),
          center.dy + innerR * sin(angle));

      final tickPaint = Paint()
        ..color = accentColor
        ..strokeWidth = isMajor ? 3 : 1.5;
      canvas.drawLine(p1, p2, tickPaint);

      if (isMajor) {
        final numR = radius - 42;
        final numPos = Offset(center.dx + numR * cos(angle),
            center.dy + numR * sin(angle));
        final textPainter = TextPainter(
          text: TextSpan(
            text: v.toInt().toString(),
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(numPos.dx - textPainter.width / 2,
              numPos.dy - textPainter.height / 2),
        );
      }
    }

    final clampedSpeed = speed.clamp(0, maxSpeed);
    final needleAngle = startAngle + (clampedSpeed / maxSpeed) * sweepTotal;
    final needleEnd = Offset(
      center.dx + (radius - 40) * cos(needleAngle),
      center.dy + (radius - 40) * sin(needleAngle),
    );
    final needlePaint = Paint()
      ..color = needleColor
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, needleEnd, needlePaint);
    canvas.drawCircle(center, 7, Paint()..color = needleColor);

    final speedText = TextPainter(
      text: TextSpan(
        text: speed.toStringAsFixed(0),
        style: TextStyle(
            color: needleColor, fontSize: 32, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    );
    speedText.layout();
    speedText.paint(
      canvas,
      Offset(center.dx - speedText.width / 2, center.dy + 28),
    );

    final mphText = TextPainter(
      text: const TextSpan(
        text: 'MPH',
        style: TextStyle(color: Colors.grey, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    );
    mphText.layout();
    mphText.paint(
      canvas,
      Offset(center.dx - mphText.width / 2, center.dy + 62),
    );
  }

  @override
  bool shouldRepaint(covariant RealGaugePainter oldDelegate) => true;
}

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
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) _returnResult();
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

class ColorPickerScreen extends StatefulWidget {
  const ColorPickerScreen({super.key});

  @override
  State<ColorPickerScreen> createState() => _ColorPickerScreenState();
}

class _ColorPickerScreenState extends State<ColorPickerScreen> {
  late double _hue;
  final GlobalKey _barKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(accentColorController.value);
    _hue = hsv.hue;
  }

  Color get _currentColor => HSVColor.fromAHSV(1.0, _hue, 0.85, 0.85).toColor();

  void _handlePosition(Offset globalPosition) {
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final width = box.size.width;
    final t = (local.dx / width).clamp(0.0, 1.0);
    setState(() => _hue = t * 360);
    accentColorController.value = _currentColor;
  }

  Future<void> _saveAndExit() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accentColor', _currentColor.value);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App Color')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: _currentColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey.shade800, width: 2),
              ),
            ),
            const SizedBox(height: 32),
            GestureDetector(
              onPanUpdate: (details) => _handlePosition(details.globalPosition),
              onTapDown: (details) => _handlePosition(details.globalPosition),
              child: Container(
                key: _barKey,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(colors: [
                    Color(0xFFFF0000),
                    Color(0xFFFFFF00),
                    Color(0xFF00FF00),
                    Color(0xFF00FFFF),
                    Color(0xFF0000FF),
                    Color(0xFFFF00FF),
                    Color(0xFFFF0000),
                  ]),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final left = (_hue / 360 * width - 16)
                        .clamp(0.0, width - 32);
                    return Stack(
                      children: [
                        Positioned(
                          left: left,
                          top: 4,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border:
                                  Border.all(color: Colors.black, width: 2),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Drag the dot to pick your app color',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saveAndExit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentColor,
                foregroundColor: Colors.black,
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
