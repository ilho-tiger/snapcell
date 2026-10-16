import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

late Directory filesDir;
late Directory outDir;

void log(String m) => debugPrint('SPIKE $m');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  filesDir = (await getExternalStorageDirectory())!;
  outDir = await Directory(p.join(filesDir.path, 'out')).create(recursive: true);
  await Process.run('chmod', ['777', outDir.path]);
  await Directory(p.join(filesDir.path, 'fixtures')).create(recursive: true);
  // Item 5: whether to call retrieveLostData at startup is a file flag so it
  // survives the activity being killed ("Don't keep activities").
  final flag = File(p.join(filesDir.path, 'no_lost_data_call'));
  if (await flag.exists()) {
    log('startup: retrieveLostData SKIPPED (flag file present)');
  } else {
    final r = await ImagePicker().retrieveLostData();
    log('startup: retrieveLostData isEmpty=${r.isEmpty} files=${r.files?.map((f) => f.path).toList()} '
        'exception=${r.exception} type=${r.type}');
    for (final f in r.files ?? <XFile>[]) {
      await describe('lost', f);
    }
  }
  runApp(const MaterialApp(home: Home()));
}

String sha(File f) => sha256.convert(f.readAsBytesSync()).toString();

/// Logs path, size and sha256, and copies the file out so it can be pulled.
Future<void> describe(String tag, XFile x, [int? i]) async {
  final f = File(x.path);
  final len = await f.length();
  final copy = p.join(outDir.path, '${tag}_${i ?? 0}_${p.basename(x.path)}');
  await f.copy(copy);
  await Process.run('chmod', ['666', copy]); // app umask is 0600; adb shell must read it
  log('FILE $tag[$i] path=${x.path} name=${x.name} bytes=$len sha=${sha(f)} copy=$copy');
}

/// Normalized centroid of the white marker block. Upright synthetic image: about (0.08, 0.20).
String whiteCentroid(List<int> rgba, int w, int h) {
  var sx = 0, sy = 0, n = 0;
  for (var y = 0; y < h; y += 4) {
    for (var x = 0; x < w; x += 4) {
      final i = (y * w + x) * 4;
      if (rgba[i] > 240 && rgba[i + 1] > 240 && rgba[i + 2] > 240) {
        sx += x;
        sy += y;
        n++;
      }
    }
  }
  if (n == 0) return 'none';
  return '(${(sx / n / w).toStringAsFixed(2)},${(sy / n / h).toStringAsFixed(2)})';
}

/// Pure-Dart downscale as in ADR-0004 (top-level so the isolate closure captures only strings).
(int, int, int, int, List<int>, int, int, int) dartDownscaleJob(String path) {
  final sw = Stopwatch()..start();
  final bytes = File(path).readAsBytesSync();
  final src = img.decodeJpg(bytes)!;
  final decodeMs = sw.elapsedMilliseconds;
  final small = img.copyResize(src,
      width: src.width >= src.height ? 1600 : null,
      height: src.height > src.width ? 1600 : null,
      interpolation: img.Interpolation.average);
  final resizeMs = sw.elapsedMilliseconds - decodeMs;
  final out = img.encodeJpg(small, quality: 85);
  final encodeMs = sw.elapsedMilliseconds - decodeMs - resizeMs;
  return (src.width, src.height, small.width, small.height, out, decodeMs, resizeMs, encodeMs);
}

/// Not async and not a method, so the isolate closure captures nothing but the path.
Future<(int, int, int, int, List<int>, int, int, int)> runDartDownscale(String path) =>
    Isolate.run(() => dartDownscaleJob(path));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String status = 'ready';
  final limitCtl = TextEditingController(text: '20');
  XFile? lastUnresized;

  Future<void> pick(String tag, {double? max, int? q, int? limit}) async {
    setState(() => status = 'picking $tag');
    final sw = Stopwatch()..start();
    try {
      final files = await ImagePicker().pickMultiImage(
        maxWidth: max,
        maxHeight: max,
        imageQuality: q,
        limit: limit,
      );
      log('PICK $tag max=$max q=$q limit=$limit returned=${files.length} ms=${sw.elapsedMilliseconds}');
      for (var i = 0; i < files.length; i++) {
        await describe(tag, files[i], i);
      }
      if (max == null && files.isNotEmpty) lastUnresized = files.first;
      setState(() => status = '$tag: ${files.length} files, ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      log('PICK $tag ERROR $e');
      setState(() => status = '$tag error: $e');
    }
  }


  List<File> synthetic = [];

  /// Item 4: how do Flutter's codec and the `image` package treat the EXIF
  /// orientation tag in the files in out/? Logs decoded sizes; shows synthetic
  /// (small) files only, since the real photos are private.
  Future<void> decodeCheck() async {
    final files = outDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpg'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final small = <File>[];
    for (final f in files) {
      final bytes = f.readAsBytesSync();
      final codec = await ui.instantiateImageCodec(bytes);
      final fr = await codec.getNextFrame();
      final w = fr.image.width, h = fr.image.height;
      final rgba = (await fr.image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final flutterWhite = whiteCentroid(rgba, w, h);
      fr.image.dispose();
      final codecT = await ui.instantiateImageCodec(bytes, targetWidth: 343);
      final frT = await codecT.getNextFrame();
      final tw = frT.image.width, th = frT.image.height;
      frT.image.dispose();
      final d = img.decodeJpg(bytes)!;
      final tag = d.exif.imageIfd.orientation;
      final baked = img.bakeOrientation(d);
      log('DECODE ${p.basename(f.path)} bytes=${bytes.length} '
          'flutterCodec=${w}x$h flutterCodecTarget343=${tw}x$th '
          'imagePkg=${d.width}x${d.height} exifOrientation=$tag baked=${baked.width}x${baked.height} '
          'whiteFlutter=$flutterWhite whiteImagePkg=${whiteCentroid(d.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba), d.width, d.height)} '
          'whiteBaked=${whiteCentroid(baked.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba), baked.width, baked.height)}');
      if (bytes.length < 200000) small.add(f);
    }
    setState(() {
      synthetic = small;
      status = 'decode check done (${files.length} files)';
    });
  }

  Future<void> dartDownscale() async {
    // Uses the pushed original (same bytes as an unresized pick, minus GPS redaction).
    final name = lastUnresized?.path ?? p.join(filesDir.path, 'fixtures', 'big50.jpg');
    final sw = Stopwatch()..start();
    try {
      final r = await runDartDownscale(name);
      final dd = File(p.join(outDir.path, 'dart_downscale.jpg'))..writeAsBytesSync(r.$5);
      await Process.run('chmod', ['666', dd.path]);
      log('DARTDOWN in=${r.$1}x${r.$2} out=${r.$3}x${r.$4} bytes=${r.$5.length} '
          'totalMs=${sw.elapsedMilliseconds} decodeMs=${r.$6} resizeMs=${r.$7} encodeMs=${r.$8}');
      setState(() => status = 'dart downscale ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      log('DARTDOWN ERROR $e');
      setState(() => status = 'dart downscale error: $e');
    }
  }

  Future<void> galSave({bool badPath = false}) async {
    final name = 'diary_2026-10-01_2026-10-18_p1.jpg';
    final src = File(p.join(filesDir.path, 'fixtures', name));
    try {
      if (badPath) {
        await Gal.putImage('/nonexistent/$name', album: 'Snapcell');
      } else {
        final tmp = File(p.join((await getTemporaryDirectory()).path, name));
        await src.copy(tmp.path);
        log('GAL src sha=${sha(tmp)} bytes=${await tmp.length()}');
        await Gal.putImage(tmp.path, album: 'Snapcell');
        log('GAL saved ok');
      }
      setState(() => status = 'gal ok');
    } on GalException catch (e) {
      log('GAL GalException type=${e.type} msg=$e');
      setState(() => status = 'gal ${e.type}');
    } catch (e) {
      log('GAL OTHER ERROR ${e.runtimeType} $e');
      setState(() => status = 'gal other: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget b(String t, VoidCallback f) =>
        Padding(padding: const EdgeInsets.all(3), child: ElevatedButton(onPressed: f, child: Text(t)));
    final limit = int.tryParse(limitCtl.text);
    return Scaffold(
      appBar: AppBar(title: const Text('exif_spike')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text(status),
        b('Pick (no resize)', () => pick('raw')),
        b('Pick (maxWidth/Height 1600)', () => pick('r1600', max: 1600)),
        b('Pick (1600, quality 85)', () => pick('r1600q85', max: 1600, q: 85)),
        b('Pick bulk (no resize, limit)', () => pick('bulkraw', limit: limit)),
        b('Pick bulk (1600, limit)', () => pick('bulk1600', max: 1600, limit: limit)),
        b('Pick bulk (1600, q85, limit)', () => pick('bulk1600q85', max: 1600, q: 85, limit: limit)),
        TextField(controller: limitCtl, decoration: const InputDecoration(labelText: 'limit')),
        b('Dart isolate downscale of last unresized pick', dartDownscale),
        const Divider(),
        b('Decode check (orientation)', decodeCheck),
        Wrap(children: [
          for (final f in synthetic)
            Padding(padding: const EdgeInsets.all(4), child: Image.file(f, width: 160)),
        ]),
        b('gal: putImage fixture', galSave),
        b('gal: putImage bad path', () => galSave(badPath: true)),
        const Divider(),
      ]),
    );
  }
}
