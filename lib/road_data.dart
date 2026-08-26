import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;

class RoadMatch {
  final int speedLimit;
  final bool onSystem;
  final double distanceMeters;

  const RoadMatch({
    required this.speedLimit,
    required this.onSystem,
    required this.distanceMeters,
  });
}

class _RoadSegment {
  final int speedLimit;
  final bool onSystem;
  final List<double> lats;
  final List<double> lngs;
  final double minLat, maxLat, minLng, maxLng;

  const _RoadSegment({
    required this.speedLimit,
    required this.onSystem,
    required this.lats,
    required this.lngs,
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });
}

class RoadNetwork {
  final List<_RoadSegment> _segments;
  final Map<String, List<int>> _grid;
  final double _cellSize;

  RoadNetwork._(this._segments, this._grid, this._cellSize);

  RoadMatch? findNearest(double lat, double lng,
      {double maxDistanceMeters = 150}) {
    final gx = (lng / _cellSize).floor();
    final gy = (lat / _cellSize).floor();
    final marginDeg = maxDistanceMeters / 111000.0;

    double bestDist = double.infinity;
    _RoadSegment? best;

    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final key = '${gx + dx}:${gy + dy}';
        final indices = _grid[key];
        if (indices == null) continue;
        for (final idx in indices) {
          final seg = _segments[idx];
          if (lat < seg.minLat - marginDeg ||
              lat > seg.maxLat + marginDeg ||
              lng < seg.minLng - marginDeg ||
              lng > seg.maxLng + marginDeg) {
            continue;
          }
          final d = _distanceToSegment(lat, lng, seg);
          if (d < bestDist) {
            bestDist = d;
            best = seg;
          }
        }
      }
    }

    if (best == null || bestDist > maxDistanceMeters) return null;
    return RoadMatch(
      speedLimit: best.speedLimit,
      onSystem: best.onSystem,
      distanceMeters: bestDist,
    );
  }

  double _distanceToSegment(double lat, double lng, _RoadSegment seg) {
    if (seg.lats.length == 1) {
      return _haversine(lat, lng, seg.lats[0], seg.lngs[0]);
    }
    double minDist = double.infinity;
    for (int i = 0; i < seg.lats.length - 1; i++) {
      final d = _pointToSegmentMeters(
          lat, lng, seg.lats[i], seg.lngs[i], seg.lats[i + 1], seg.lngs[i + 1]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  static double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  static double _pointToSegmentMeters(double plat, double plng, double lat1,
      double lng1, double lat2, double lng2) {
    final refLat = plat * pi / 180;
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * cos(refLat);

    final px = (plng - lng1) * mPerDegLng;
    final py = (plat - lat1) * mPerDegLat;
    final bx = (lng2 - lng1) * mPerDegLng;
    final by = (lat2 - lat1) * mPerDegLat;

    final lengthSq = bx * bx + by * by;
    double t = lengthSq > 0 ? (px * bx + py * by) / lengthSq : 0.0;
    t = t.clamp(0.0, 1.0);

    final closestX = t * bx;
    final closestY = t * by;
    final ddx = px - closestX;
    final ddy = py - closestY;
    return sqrt(ddx * ddx + ddy * ddy);
  }
}

RoadNetwork _parseRoadNetwork(String jsonStr) {
  final data = json.decode(jsonStr) as Map<String, dynamic>;
  final features = data['features'] as List;
  const cellSize = 0.05;

  final segments = <_RoadSegment>[];
  final grid = <String, List<int>>{};

  for (final f in features) {
    final props = f['properties'] as Map<String, dynamic>;
    final geom = f['geometry'] as Map<String, dynamic>;
    final coords = geom['coordinates'] as List;

    final lats = <double>[];
    final lngs = <double>[];
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;

    for (final c in coords) {
      final lng = (c[0] as num).toDouble();
      final lat = (c[1] as num).toDouble();
      lats.add(lat);
      lngs.add(lng);
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    final seg = _RoadSegment(
      speedLimit: props['s'] as int,
      onSystem: (props['sys'] as int) == 1,
      lats: lats,
      lngs: lngs,
      minLat: minLat,
      maxLat: maxLat,
      minLng: minLng,
      maxLng: maxLng,
    );

    final idx = segments.length;
    segments.add(seg);

    final gx1 = (minLng / cellSize).floor();
    final gx2 = (maxLng / cellSize).floor();
    final gy1 = (minLat / cellSize).floor();
    final gy2 = (maxLat / cellSize).floor();

    for (int gx = gx1; gx <= gx2; gx++) {
      for (int gy = gy1; gy <= gy2; gy++) {
        grid.putIfAbsent('$gx:$gy', () => []).add(idx);
      }
    }
  }

  return RoadNetwork._(segments, grid, cellSize);
}

Future<RoadNetwork> loadRoadNetwork() async {
  final jsonStr = await rootBundle.loadString('assets/texas_speed_limits.geojson');
  return compute(_parseRoadNetwork, jsonStr);
}
