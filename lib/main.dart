import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:math';

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
  double _currentSpeedMph = 0.0;
  int _estimatedSpeedLimit = 45;
  SpeedometerStyle _currentStyle = SpeedometerStyle.digital;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _flutterTts.setLanguage("en-US"); // إضافة ضبط اللغة للتنبيه الصوتي
    _initLocationTracking();
  }

  void _initLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((Position position) {
      double speedMph = (position.speed * 2.23694); // M/S to MPH
      setState(() {
        _currentSpeedMph = speedMph < 0 ? 0 : speedMph;
        _analyzeSpeedLimit(_currentSpeedMph);
      });
    });
  }

  void _analyzeSpeedLimit(double speed) {
    int newLimit = 45;
    if (speed > 60) {
      newLimit = 70;
    } else if (speed > 35) {
      newLimit = 45;
    } else {
      newLimit = 30;
    }

    if (newLimit != _estimatedSpeedLimit) {
      _estimatedSpeedLimit = newLimit;
    }

    if (speed > _estimatedSpeedLimit + 3 && !_isMuted) {
      _flutterTts.speak("Speed limit exceeded. Limit is $_estimatedSpeedLimit");
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
    bool isSpeeding = _currentSpeedMph > _estimatedSpeedLimit;
    Color alertColor = isSpeeding ? Colors.redAccent : Colors.greenAccent;

    return Transform(
      alignment: Alignment.center,
      transform: _currentStyle == SpeedometerStyle.hud
          ? (Matrix4.identity()..scale(1.0, -1.0)) // Reflect for HUD
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
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(
                    '$_estimatedSpeedLimit',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 36),
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
                style: TextStyle(fontSize: 80, fontWeight: FontWeight.bold, color: alertColor),
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
