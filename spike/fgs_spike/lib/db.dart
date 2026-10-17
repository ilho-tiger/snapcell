import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'db.g.dart';

class Jobs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get state => text()(); // rendering | ready
  IntColumn get total => integer()();
}

class Sheets extends Table {
  IntColumn get jobId => integer()();
  IntColumn get idx => integer()();
  TextColumn get status => text()(); // pending | rendered
  @override
  Set<Column> get primaryKey => {jobId, idx};
}

@DriftDatabase(tables: [Jobs, Sheets])
class Db extends _$Db {
  Db() : super(_open());
  @override
  int get schemaVersion => 1;

  // Same file from both isolates, so no shared connection and no isolate
  // wrapper: each isolate opens its own native connection.
  static QueryExecutor _open() => driftDatabase(
        name: 'spike',
        native: DriftNativeOptions(
          setup: (raw) {
            raw.execute('PRAGMA journal_mode=WAL');
            raw.execute('PRAGMA busy_timeout=0'); // surface lock errors
          },
        ),
      );

  Future<Job?> currentJob() =>
      (select(jobs)..orderBy([(j) => OrderingTerm.desc(j.id)])..limit(1))
          .getSingleOrNull();

  Future<int> newJob(int total) => transaction(() async {
        await delete(sheets).go();
        await delete(jobs).go();
        final id = await into(jobs)
            .insert(JobsCompanion.insert(state: 'rendering', total: total));
        for (var i = 0; i < total; i++) {
          await into(sheets).insert(
              SheetsCompanion.insert(jobId: id, idx: i, status: 'pending'));
        }
        return id;
      });

  Future<List<Sheet>> pending(int jobId) => (select(sheets)
        ..where((s) => s.jobId.equals(jobId) & s.status.equals('pending'))
        ..orderBy([(s) => OrderingTerm.asc(s.idx)]))
      .get();

  Future<void> markRendered(int jobId, int idx) =>
      (update(sheets)..where((s) => s.jobId.equals(jobId) & s.idx.equals(idx)))
          .write(const SheetsCompanion(status: Value('rendered')));

  Future<void> setState(int jobId, String state) =>
      (update(jobs)..where((j) => j.id.equals(jobId)))
          .write(JobsCompanion(state: Value(state)));

  Stream<int> renderedCount(int jobId) {
    final c = sheets.idx.count();
    return (selectOnly(sheets)
          ..addColumns([c])
          ..where(sheets.jobId.equals(jobId) & sheets.status.equals('rendered')))
        .watchSingle()
        .map((r) => r.read(c)!);
  }
}
