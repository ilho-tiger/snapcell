// Render path copied from spike 001 (shared painter, rawRgba, JPEG encode in
// an isolate). Cell layout is simplified; the question here is only whether
// it runs inside the foreground-service isolate.
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

const sheetW = 1200, sheetH = 1650, dpi = 300;
const cellW = 343, cellH = 224;
const cols = 3, rows = 6;
const photoCount = 18;

Uint8List makePhoto(int seed) {
  final im = img.Image(width: 1600, height: 1200);
  final r = math.Random(seed);
  final ph = r.nextDouble() * 6, f = 3 + r.nextInt(5);
  for (final p in im) {
    final x = p.x / 1600, y = p.y / 1200;
    final base = 128 + 100 * math.sin(f * x + ph) * math.cos(f * y);
    final fine = ((p.x ~/ 2 + p.y ~/ 2) % 2 == 0) ? 18 : -18;
    final v = (base + fine + r.nextInt(16) - 8).clamp(0, 255).toInt();
    p
      ..r = v
      ..g = (v * (0.6 + 0.4 * y)).toInt()
      ..b = (255 - v * 0.7 * x).toInt();
  }
  return img.encodeJpg(im, quality: 85);
}

/// Top-level and non-async so the isolate closure captures nothing unsendable.
Future<void> writePhotos(String dir) => Isolate.run(() {
      Directory(dir).createSync(recursive: true);
      for (var i = 0; i < photoCount; i++) {
        File('$dir/p$i.jpg').writeAsBytesSync(makePhoto(i));
      }
    });

class SheetPainter extends CustomPainter {
  final List<ui.Image> photos;
  final String label;
  SheetPainter(this.photos, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, sheetW.toDouble(), sheetH.toDouble()),
        Paint()..color = const Color(0xFFFFFFFF));
    final paint = Paint()..filterQuality = FilterQuality.medium;
    const gx = (sheetW - cols * cellW) / (cols + 1);
    const gy = (sheetH - rows * (cellH + 40)) / (rows + 1);
    for (var i = 0; i < rows * cols; i++) {
      final c = i % cols, rw = i ~/ cols;
      final x = gx + c * (cellW + gx), y = gy + rw * (cellH + 40 + gy);
      final im = photos[i % photos.length];
      canvas.drawImageRect(
          im,
          _cover(im.width.toDouble(), im.height.toDouble()),
          Rect.fromLTWH(x, y + 40, cellW.toDouble(), cellH.toDouble()),
          paint);
      final tp = TextPainter(
        text: TextSpan(
            text: '$label ${i + 1}',
            style: const TextStyle(
                color: Color(0xFF000000), fontSize: 28, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y + 4));
    }
  }

  Rect _cover(double w, double h) {
    const t = cellW / cellH;
    if (w / h > t) {
      final nw = h * t;
      return Rect.fromLTWH((w - nw) / 2, 0, nw, h);
    }
    final nh = w / t;
    return Rect.fromLTWH(0, (h - nh) / 2, w, nh);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

Future<Uint8List> encode(ui.Image im) async {
  final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
  final ttd = TransferableTypedData.fromList([bd!.buffer.asUint8List()]);
  final w = im.width, h = im.height;
  return Isolate.run(() {
    final rgba = ttd.materialize().asUint8List();
    final image = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: rgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba);
    return img.JpegEncoder(quality: 92).encode(image);
  });
}

/// Renders sheet [idx] to `<dir>/p<idx>.jpg` via a tmp file and rename.
/// Returns (renderMs, encodeMs, bytes).
Future<(int, int, int)> renderSheetFile(
    String photosDir, String outDir, int idx) async {
  final sw = Stopwatch()..start();
  final photos = <ui.Image>[];
  for (var i = 0; i < photoCount; i++) {
    final codec = await ui
        .instantiateImageCodec(File('$photosDir/p$i.jpg').readAsBytesSync());
    photos.add((await codec.getNextFrame()).image);
    codec.dispose();
  }
  final rec = ui.PictureRecorder();
  SheetPainter(photos, 'Sheet ${idx + 1}')
      .paint(Canvas(rec), Size(sheetW.toDouble(), sheetH.toDouble()));
  final pic = rec.endRecording();
  final im = await pic.toImage(sheetW, sheetH);
  pic.dispose();
  final renderMs = sw.elapsedMilliseconds;
  final jpeg = await encode(im);
  final encMs = sw.elapsedMilliseconds - renderMs;
  im.dispose();
  for (final p in photos) {
    p.dispose();
  }
  Directory(outDir).createSync(recursive: true);
  final tmp = File('$outDir/p$idx.jpg.tmp')..writeAsBytesSync(jpeg, flush: true);
  tmp.renameSync('$outDir/p$idx.jpg');
  return (renderMs, encMs, jpeg.length);
}
