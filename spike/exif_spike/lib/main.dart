import 'dart:io';
import 'dart:isolate';

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
  log('FILE $tag[$i] path=${x.path} name=${x.name} bytes=$len sha=${sha(f)} copy=$copy');
}

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

  Future<void> dartDownscale() async {
    final x = lastUnresized;
    if (x == null) return setState(() => status = 'pick unresized first');
    final sw = Stopwatch()..start();
    try {
      final r = await Isolate.run(() {
        final src = img.decodeJpg(File(x.path).readAsBytesSync())!;
        final decodeMs = 0;
        final small = img.copyResize(src,
            width: src.width >= src.height ? 1600 : null,
            height: src.height > src.width ? 1600 : null,
            interpolation: img.Interpolation.average);
        final out = img.encodeJpg(small, quality: 85);
        return (src.width, src.height, small.width, small.height, out, decodeMs);
      });
      File(p.join(outDir.path, 'dart_downscale.jpg')).writeAsBytesSync(r.$5);
      log('DARTDOWN in=${r.$1}x${r.$2} out=${r.$3}x${r.$4} bytes=${r.$5.length} ms=${sw.elapsedMilliseconds}');
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
        TextField(controller: limitCtl, decoration: const InputDecoration(labelText: 'limit')),
        b('Dart isolate downscale of last unresized pick', dartDownscale),
        const Divider(),
        b('gal: putImage fixture', galSave),
        b('gal: putImage bad path', () => galSave(badPath: true)),
        const Divider(),
        if (lastUnresized != null) Image.file(File(lastUnresized!.path), height: 200),
      ]),
    );
  }
}
