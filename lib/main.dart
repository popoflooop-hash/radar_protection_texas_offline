import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:math';
import 'road_data.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TexasSpeedGuardApp());
}

class TexasSpeedGuardApp extends StatelessWidget {
  const TexasSpeedGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Texas Speed Guard',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E21),
        primaryColor: const Color(0xFF1D1E33),
      ),
      home: const SpeedometerScreen(),
    );
  }
}

enum SpeedometerStyle { digital, analogGauge, hud }

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
  bool _hasWarnedForCurrentLimit = false;

  RoadNetwork? _roadNetwork;
  bool _roadDataFailed = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _flutterTts.setLanguage("en-US");
    _loadRoadData();
    _initLocationTracking();
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
      if (_estimatedSpeedLimit != null) {
        _estimatedSpeedLimit = null;
        _speedLimitConfirmed = false;
        _hasWarnedForCurrentLimit = false;
      }
      return;
    }

    if (_estimatedSpeedLimit != match.speedLimit) {
      _estimatedSpeedLimit = match.speedLimit;
      _hasWarnedForCurrentLimit = false;
    }
    _speedLimitConfirmed = true;
  }

  void _checkOverspeedWarning(double speed) {
    final limit = _estimatedSpeedLimit;
    if (limit == null) return;

    bool isOverLimit = speed > limit + 3;

    if (isOverLimit && !_isMuted && !_hasWarnedForCurrentLimit) {
      _hasWarnedForCurrentLimit = true;
      _flutterTts.speak("Speed limit exceeded. Limit is $limit");
    } else if (!isOverLimit) {
      _hasWarnedForCurrentLimit = false;
    }
  }

  void _toggleStyle() {
    setState(() {
      if (_currentStyle == SpeedometerStyle.digital) {
        _currentStyle = SpeedometerStyle.analogGauge;
      } else if (_currentStyle == SpeedometerStyle.analogGauge) {
        _currentStyle = SpeedometerStyle.hud;
      } else {
        _currentStyle = SpeedometerStyle.digital;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final limit = _estimatedSpeedLimit;
    bool isSpeeding = limit != null && _currentSpeedMph > limit;
    Color alertColor = limit == null
        ? Colors.grey
        : (isSpeeding ? Colors.redAccent : Colors.greenAccent);

    return Transform(
      alignment: Alignment.center,
      transform: _currentStyle == SpeedometerStyle.hud
          ? (Matrix4.identity()..scale(1.0, -1.0))
          : Matrix4.identity(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Texas Speed Guard'),
          centerTitle: true,
          backgroundColor: const Color(0xFF1D1E33),
          actions: [
            IconButton(
              icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up),
              onPressed: () => setState(() => _isMuted = !_isMuted),
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
                  'جاري تحميل بيانات الطرق...',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            if (_roadDataFailed)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'تعذّر تحميل بيانات حدود السرعة',
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
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1D1E33),
                    foregroundColor: Colors.white,
                  ),
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
                      _speedLimitConfirmed ? '(من بيانات TxDOT الرسمية)' : '',
                      style: const TextStyle(color: Colors.black54, fontSize: 10),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String _getStyleName(SpeedometerStyle style) {
    switch (style) {
      case SpeedometerStyle.digital:
        return 'وضع: رقمي بسيط';
      case SpeedometerStyle.analogGauge:
        return 'وضع: عداد رياضي';
      case SpeedometerStyle.hud:
        return 'وضع: انعكاس زجاجي (HUD)';
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
      case SpeedometerStyle.digital:
      default:
        return Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: alertColor, width: 8),
            color: const Color(0xFF111328),
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
