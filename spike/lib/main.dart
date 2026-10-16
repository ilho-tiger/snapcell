// Throwaway spike for issue #1 (ADR-0001 export pipeline). Not merged to main.
// Output: lines prefixed "SPIKE " on logcat, plus sample files in the app's
// external files dir for pulling to the host.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

const sheetW = 1200, sheetH = 1650, dpi = 300;
const cellW = 343, cellH = 224; // 29 x 19 mm at 300 DPI
const cols = 3, rows = 6; // 18 cells per sheet
late final String outDir;

void log(String s) => debugPrint('SPIKE $s');

// ---- memory sampling -------------------------------------------------------
class PeakRss {
  int peak = 0;
  late final Timer _t;
  PeakRss() {
    _t = Timer.periodic(const Duration(milliseconds: 20), (_) => sample());
  }
  void sample() => peak = math.max(peak, ProcessInfo.currentRss);
  int stop() {
    _t.cancel();
    sample();
    return peak;
  }
}

String mb(int b) => (b / 1048576).toStringAsFixed(0);

// ---- synthetic photos ------------------------------------------------------
// No real photos on the emulator: smooth gradients + fine texture + hard edges.
Uint8List makePhoto(int seed) {
  final im = img.Image(width: 1600, height: 1200);
  final r = math.Random(seed);
  final ph = r.nextDouble() * 6, f = 3 + r.nextInt(5);
  for (final p in im) {
    final x = p.x / 1600, y = p.y / 1200;
    final base = 128 + 100 * math.sin(f * x + ph) * math.cos(f * y);
    final fine = ((p.x ~/ 2 + p.y ~/ 2) % 2 == 0) ? 18 : -18; // 2px checker
    final stripe = (p.x % 7 < 1) ? 40 : 0; // thin vertical lines
    final n = r.nextInt(16) - 8;
    final v = (base + fine + stripe + n).clamp(0, 255).toInt();
    p
      ..r = v
      ..g = (v * (0.6 + 0.4 * y)).toInt()
      ..b = (255 - v * 0.7 * x).toInt();
  }
  img.drawCircle(im,
      x: 800, y: 600, radius: 300, color: img.ColorRgb8(255, 255, 255));
  return img.encodeJpg(im, quality: 85);
}

// ---- the shared painter (sheet space only) ---------------------------------
class SheetPainter extends CustomPainter {
  final List<ui.Image> photos;
  final FilterQuality quality;
  final String label;
  SheetPainter(this.photos, this.quality, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    // Opaque white first: rawRgba is premultiplied.
    canvas.drawRect(Rect.fromLTWH(0, 0, sheetW.toDouble(), sheetH.toDouble()),
        Paint()..color = const Color(0xFFFFFFFF));
    final paint = Paint()..filterQuality = quality;
    const gx = (sheetW - cols * cellW) / (cols + 1);
    const gy = (sheetH - rows * (cellH + 40)) / (rows + 1);
    for (var i = 0; i < rows * cols; i++) {
      final c = i % cols, rw = i ~/ cols;
      final x = gx + c * (cellW + gx), y = gy + rw * (cellH + 40 + gy);
      final dst = Rect.fromLTWH(x, y + 40, cellW.toDouble(), cellH.toDouble());
      final im = photos[i % photos.length];
      final src = _cover(im.width.toDouble(), im.height.toDouble());
      canvas.drawImageRect(im, src, dst, paint);
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

Future<ui.Image> renderSheet(List<ui.Image> photos, FilterQuality q,
    {double scale = 1}) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  if (scale != 1) canvas.scale(scale);
  SheetPainter(photos, q, 'May 12')
      .paint(canvas, Size(sheetW.toDouble(), sheetH.toDouble()));
  final pic = rec.endRecording();
  final im = await pic.toImage(
      (sheetW * scale).round(), (sheetH * scale).round());
  pic.dispose();
  return im;
}

Future<ui.Image> decode(Uint8List bytes, {int? targetWidth}) async {
  final codec =
      await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
  final f = await codec.getNextFrame();
  codec.dispose();
  return f.image;
}

// ---- encode + DPI ----------------------------------------------------------
Future<Uint8List> encodeInIsolate(ui.Image im, {int quality = 92}) async {
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
    // EXIF resolution, for consumers that ignore JFIF density.
    image.exif.imageIfd.xResolution = [dpi, 1];
    image.exif.imageIfd.yResolution = [dpi, 1];
    image.exif.imageIfd[0x0128] = img.IfdValueShort(2); // ResolutionUnit inch
    return img.JpegEncoder(quality: quality).encode(image);
  });
}

/// Patch JFIF APP0 to unit=1 (dpi), density = [d]. Returns false if no APP0.
bool patchJfifDensity(Uint8List jpeg, int d) {
  // SOI(2) then APP0: FF E0 len(2) "JFIF\0" ver(2) unit(1) xd(2) yd(2)
  if (jpeg[2] != 0xFF || jpeg[3] != 0xE0) return false;
  jpeg[13] = 1;
  jpeg[14] = d >> 8;
  jpeg[15] = d & 0xFF;
  jpeg[16] = d >> 8;
  jpeg[17] = d & 0xFF;
  return true;
}

String jfifInfo(Uint8List j) =>
    'APP0 marker=${j[2].toRadixString(16)}${j[3].toRadixString(16)} '
    'unit=${j[13]} x=${(j[14] << 8) | j[15]} y=${(j[16] << 8) | j[17]}';

Future<void> decodeMode(String mode, List<Uint8List> photoBytes) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    log('PHASE start decode_$mode');
    final pk = PeakRss();
    final sw = Stopwatch()..start();
    final tw = mode.startsWith('b') ? cellW : null;
    // One sheet's worth (18 photos), repeated; hold between reps so the host
    // poller can see the plateau.
    for (var rep = 0; rep < 5; rep++) {
      if (mode.endsWith('allAtOnce')) {
        final ims = [for (final b in photoBytes) await decode(b, targetWidth: tw)];
        pk.sample();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        for (final i in ims) {
          i.dispose();
        }
      } else {
        for (final b in photoBytes) {
          final i = await decode(b, targetWidth: tw);
          pk.sample();
          i.dispose();
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
    log('PHASE end decode_$mode: ${sw.elapsedMilliseconds}ms (5 reps incl 600ms holds) '
        'peakRss=${mb(pk.stop())}MB');
    await Future<void>.delayed(const Duration(seconds: 2));
}

// ---- main ------------------------------------------------------------------
Future<void> run() async {
  outDir = (await getExternalStorageDirectory())!.path;
  log('outDir=$outDir');
  final t0 = Stopwatch()..start();
  final photoBytes =
      await Isolate.run(() => [for (var i = 0; i < 18; i++) makePhoto(i)]);
  log('photos generated: n=${photoBytes.length} '
      'avgKB=${photoBytes.fold<int>(0, (a, b) => a + b.length) ~/ photoBytes.length ~/ 1024} '
      'in ${t0.elapsedMilliseconds}ms');
  log('baseline rss=${mb(ProcessInfo.currentRss)}MB');

  // Item 8: decode strategies, one sheet's worth (18 photos).
  final modeFile = File('$outDir/mode.txt');
  if (modeFile.existsSync()) {
    // Isolated run: one decode strategy per fresh process.
    await decodeMode(modeFile.readAsStringSync().trim(), photoBytes);
    log('DONE');
    return;
  }
  for (final mode in ['a_full_allAtOnce', 'a_full_sequential', 'b_target_allAtOnce', 'b_target_sequential']) {
    await decodeMode(mode, photoBytes);
  }
  await Future<void>.delayed(const Duration(seconds: 2));

  // Items 1,2,5: single sheet, full pipeline with timing breakdown.
  final photos = [for (final b in photoBytes) await decode(b)];
  var sw = Stopwatch()..start();
  final sheet = await renderSheet(photos, FilterQuality.medium);
  final tRender = sw.elapsedMilliseconds;
  sw.reset();
  final rgba = (await sheet.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  final tRead = sw.elapsedMilliseconds;
  var minA = 255;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] < minA) minA = rgba[i];
  }
  log('alpha: minAlpha=$minA (255 = fully opaque)');
  sw.reset();
  final jpeg = await encodeInIsolate(sheet);
  final tEnc = sw.elapsedMilliseconds;
  log('single sheet ${sheet.width}x${sheet.height}: render+toImage=${tRender}ms '
      'toByteData=${tRead}ms encode(isolate)=${tEnc}ms size=${jpeg.length ~/ 1024}KB');
  log('JFIF before patch: ${jfifInfo(jpeg)}');
  final patched = patchJfifDensity(jpeg, dpi);
  log('JFIF after patch (patched=$patched): ${jfifInfo(jpeg)}');
  File('$outDir/sheet_300dpi.jpg').writeAsBytesSync(jpeg);

  // Item 3: downscale quality. Reference = box-filter average resize.
  final srcImg = img.decodeJpg(photoBytes[0])!;
  final refCell = img.copyResize(
      img.copyCrop(srcImg,
          x: (1600 - (1200 * cellW / cellH).round()) ~/ 2,
          y: 0,
          width: (1200 * cellW / cellH).round(),
          height: 1200),
      width: cellW,
      height: cellH,
      interpolation: img.Interpolation.average);
  for (final q in FilterQuality.values) {
    final one = await renderSheet([photos[0]], q);
    final bytes = (await one.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    final sheetImg = img.Image.fromBytes(
        width: sheetW,
        height: sheetH,
        bytes: bytes.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba);
    // cell 0 position (see SheetPainter)
    const gx = (sheetW - cols * cellW) / (cols + 1);
    const gy = (sheetH - rows * (cellH + 40)) / (rows + 1);
    final crop = img.copyCrop(sheetImg,
        x: gx.round(), y: (gy + 40).round(), width: cellW, height: cellH);
    var sum = 0.0;
    for (final p in crop) {
      final r = refCell.getPixel(p.x, p.y);
      sum += (p.r - r.r).abs() + (p.g - r.g).abs() + (p.b - r.b).abs();
    }
    log('downscale ${q.name}: MAE vs box-filter reference = '
        '${(sum / (cellW * cellH * 3)).toStringAsFixed(2)} (0-255)');
    File('$outDir/cell_${q.name}.png')
        .writeAsBytesSync(img.encodePng(crop));
    one.dispose();
  }
  File('$outDir/cell_reference.png').writeAsBytesSync(img.encodePng(refCell));

  // Item 4: preview/export parity. Preview at 0.3x via canvas.scale vs export
  // downscaled with a box filter.
  final prev = await renderSheet(photos, FilterQuality.medium, scale: 0.3);
  final prevBytes = (await prev.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  final prevImg = img.Image.fromBytes(
      width: prev.width,
      height: prev.height,
      bytes: prevBytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  final expImg = img.Image.fromBytes(
      width: sheetW,
      height: sheetH,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  final expSmall = img.copyResize(expImg,
      width: prev.width,
      height: prev.height,
      interpolation: img.Interpolation.average);
  var psum = 0.0;
  for (final p in prevImg) {
    final e = expSmall.getPixel(p.x, p.y);
    psum += (p.r - e.r).abs() + (p.g - e.g).abs() + (p.b - e.b).abs();
  }
  log('parity preview(0.3x canvas.scale) vs export downscaled: '
      'MAE=${(psum / (prev.width * prev.height * 3)).toStringAsFixed(2)}');
  // Text bounds are computed in sheet space, so layout is scale-independent:
  final tp = TextPainter(
      text: const TextSpan(text: 'May 12 1', style: TextStyle(fontSize: 28, height: 1)),
      textDirection: TextDirection.ltr)
    ..layout();
  log('label layout (sheet space) size=${tp.width.toStringAsFixed(1)}x${tp.height.toStringAsFixed(1)}');
  File('$outDir/preview_0.3x.png').writeAsBytesSync(img.encodePng(prevImg));
  prev.dispose();

  // Item 7: 5 sheets back to back, sequential decode-draw-dispose.
  final frame = <int>[];
  final pk = PeakRss();
  final baseRss = ProcessInfo.currentRss;
  for (final i in photos) {
    i.dispose();
  }
  sheet.dispose();
  log('PHASE start multi');
  var maxFrameGap = 0;
  final ticker = Stopwatch()..start();
  var last = 0;
  final jank = Timer.periodic(const Duration(milliseconds: 8), (_) {
    final now = ticker.elapsedMilliseconds;
    maxFrameGap = math.max(maxFrameGap, now - last);
    last = now;
  });
  for (var s = 0; s < 5; s++) {
    final sw2 = Stopwatch()..start();
    final ims = <ui.Image>[
      for (var k = 0; k < 18; k++)
        await decode(photoBytes[(k + s * 5) % 18], targetWidth: cellW * 2)
    ];
    final tDec = sw2.elapsedMilliseconds;
    final sh = await renderSheet(ims, FilterQuality.medium);
    for (final i in ims) {
      i.dispose();
    }
    final j = await encodeInIsolate(sh);
    sh.dispose();
    patchJfifDensity(j, dpi);
    PaintingBinding.instance.imageCache.clear();
    frame.add(sw2.elapsedMilliseconds);
    log('multi sheet ${s + 1}: total=${sw2.elapsedMilliseconds}ms decode=${tDec}ms '
        'size=${j.length ~/ 1024}KB rss=${mb(ProcessInfo.currentRss)}MB '
        'imageCacheBytes=${PaintingBinding.instance.imageCache.currentSizeBytes}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (s == 4) File('$outDir/multi_last.jpg').writeAsBytesSync(j);
  }
  jank.cancel();
  log('multi: baseRss=${mb(baseRss)}MB peakRss=${mb(pk.stop())}MB '
      'finalRss=${mb(ProcessInfo.currentRss)}MB maxEventLoopGap=${maxFrameGap}ms '
      '(8ms timer; >32ms means UI isolate blocked)');
  log('PHASE end multi');
  await Future<void>.delayed(const Duration(seconds: 2));
  log('DONE');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  run().catchError((Object e, StackTrace s) => log('ERROR $e\n$s'));
}
