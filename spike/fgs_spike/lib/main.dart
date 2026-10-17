import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'render.dart';
import 'service.dart';

const total = 20;

void main() {
  FlutterForegroundTask.initCommunicationPort();
  log('UI main tag=$isolateTag');
  runApp(const MaterialApp(home: Home()));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final db = Db();
  int? jobId;
  String status = 'idle';
  bool hammer = false;
  int reads = 0, readErrors = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'generation_progress',
        channelName: 'Generation progress',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeIfNeeded());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) => log('UI lifecycle $s');

  Future<void> _resumeIfNeeded() async {
    final job = await db.currentJob();
    if (job == null) return;
    setState(() => jobId = job.id);
    final pending = await db.pending(job.id);
    final running = await FlutterForegroundTask.isRunningService;
    log('UI startup job=${job.id} state=${job.state} pending=${pending.length} serviceRunning=$running');
    if (job.state == 'rendering' && pending.isNotEmpty && !running) {
      await _startService('resume');
    }
  }

  Future<void> _startService(String why) async {
    final r = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Snapcell',
      notificationText: 'Rendering ($why)',
      notificationButtons: [const NotificationButton(id: 'cancel', text: 'Cancel')],
      callback: startCallback,
    );
    log('UI startService($why) -> $r');
    setState(() => status = 'start: $r');
  }

  Future<void> _newJob() async {
    final support = (await getApplicationSupportDirectory()).path;
    if (!Directory('$support/photos').existsSync()) {
      await writePhotos('$support/photos');
    }
    final id = await db.newJob(total);
    setState(() => jobId = id);
    log('UI newJob=$id');
    await _startService('new');
  }

  Future<void> _askPermission() async {
    final p = await FlutterForegroundTask.requestNotificationPermission();
    log('UI notification permission -> $p');
    setState(() => status = 'permission: $p');
  }

  Future<void> _hammerLoop() async {
    // Item 7: UI-isolate reads while the service isolate writes.
    while (hammer && mounted) {
      try {
        final j = await db.currentJob();
        if (j != null) await db.pending(j.id);
        reads++;
      } catch (e) {
        readErrors++;
        log('UI read error: $e');
      }
      if (reads % 50 == 0) {
        log('UI reads=$reads errors=$readErrors');
        setState(() {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    log('UI hammer stopped reads=$reads errors=$readErrors');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fgs spike')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, children: [
            ElevatedButton(onPressed: _askPermission, child: const Text('Notif perm')),
            ElevatedButton(onPressed: _newJob, child: const Text('New 20-sheet job')),
            ElevatedButton(
                onPressed: () => _startService('manual'), child: const Text('Resume')),
            ElevatedButton(
                onPressed: () {
                  hammer = !hammer;
                  if (hammer) _hammerLoop();
                  setState(() {});
                },
                child: Text(hammer ? 'Stop reads' : 'Hammer reads')),
          ]),
          const SizedBox(height: 16),
          Text('status: $status'),
          Text('reads=$reads readErrors=$readErrors'),
          if (jobId != null)
            StreamBuilder<int>(
              stream: db.renderedCount(jobId!),
              builder: (_, s) => Text('rendered ${s.data ?? 0} / $total'),
            ),
        ]),
      ),
    );
  }
}
