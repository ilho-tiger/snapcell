import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'render.dart';

/// Per-isolate top-level state: differs between isolates.
final isolateTag = DateTime.now().microsecondsSinceEpoch % 100000;

void log(String s) => debugPrint('SPIKE $s');

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(RenderHandler());

class RenderHandler extends TaskHandler {
  Db? _db;
  bool _cancel = false;
  final _notes = FlutterLocalNotificationsPlugin();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    log('SVC onStart starter=${starter.name} isolate=${Isolate.current.debugName} tag=$isolateTag pid=$pid');
    _db = Db();
    await _notes.initialize(
        settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    unawaited(_run());
  }

  Future<void> _run() async {
    final db = _db!;
    final job = await db.currentJob();
    if (job == null) {
      log('SVC no job');
      return;
    }
    final support = (await getApplicationSupportDirectory()).path;
    final todo = await db.pending(job.id);
    log('SVC job=${job.id} total=${job.total} pending=${todo.length}');
    var done = job.total - todo.length;
    for (final s in todo) {
      if (_cancel) {
        log('SVC cancelled');
        break;
      }
      try {
        final (r, e, n) = await renderSheetFile(
            '$support/photos', '$support/sheets/${job.id}', s.idx);
        await db.markRendered(job.id, s.idx);
        done++;
        log('SVC sheet ${s.idx} render=${r}ms encode=${e}ms ${n ~/ 1024}KB');
        FlutterForegroundTask.updateService(
            notificationText: 'Rendering sheet $done of ${job.total}');
        FlutterForegroundTask.sendDataToMain({'done': done});
      } catch (e, st) {
        log('SVC sheet ${s.idx} FAILED $e\n$st');
        break;
      }
    }
    if (done == job.total) {
      await db.setState(job.id, 'ready');
      log('SVC job complete');
      await _notes.show(
          id: 1,
          title: 'Sheets ready',
          body: '${job.total} sheets are ready to preview',
          notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails('generation_done', 'Done')));
    }
    await FlutterForegroundTask.stopService();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    log('SVC onDestroy isTimeout=$isTimeout');
    await _db?.close();
  }

  @override
  void onNotificationButtonPressed(String id) {
    log('SVC button $id');
    if (id == 'cancel') _cancel = true;
  }
}
