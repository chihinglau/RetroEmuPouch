import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/data/cloud/cloud_save_models.dart';
import 'package:retroemupouch/data/cloud/cloud_save_sync.dart';

class _FakeTransport implements CloudSaveTransport {
  final Map<String, CloudSaveSummary> store = {};
  final Map<String, List<int>> contents = {}; // blobId -> 明文（模拟解密后）
  final List<({String saveName, String clientKey})> calls = [];
  final Set<String> failDownloadIds = {};
  String? failWhenNameContains;
  DateTime? _last;

  /// 严格递增的上传时间（Windows 上连续两次 `DateTime.now()` 可能相等，
  /// 会让「取最新一份」的断言变成偶发失败）。
  DateTime _stamp() {
    final n = DateTime.now();
    _last = (_last == null || n.isAfter(_last!))
        ? n
        : _last!.add(const Duration(milliseconds: 10));
    return _last!;
  }

  @override
  Future<String> uploadSave({
    required String saveName,
    required String clientKey,
    required File file,
    required String passphrase,
  }) async {
    calls.add((saveName: saveName, clientKey: clientKey));
    if (failWhenNameContains != null &&
        saveName.contains(failWhenNameContains!)) {
      throw StateError('boom: $saveName');
    }
    final existing = store[clientKey];
    // 后端语义：同一 client_key 覆盖原 blob（id 不变）。
    final id = existing?.id ?? 'id-${store.length}';
    final now = _stamp();
    final bytes = file.readAsBytesSync();
    contents[id] = bytes;
    store[clientKey] = CloudSaveSummary(
      id: id,
      saveName: saveName,
      sizeBytes: bytes.length,
      sha256: 'x' * 64,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    return id;
  }

  @override
  Future<List<CloudSaveSummary>> listSaves() async => store.values.toList();

  @override
  Future<int> downloadSave(String saveId,
      {required File dest, required String passphrase}) async {
    if (failDownloadIds.contains(saveId)) throw StateError('download failed');
    final bytes = contents[saveId] ?? const <int>[];
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(bytes);
    return bytes.length;
  }

  @override
  Future<void> deleteSave(String saveId) async {}

  /// 把某个 clientKey 的云端时间往前拨（模拟「云端是旧版本」）。
  void age(String clientKey, Duration d) {
    final s = store[clientKey];
    if (s == null) return;
    store[clientKey] = CloudSaveSummary(
      id: s.id,
      saveName: s.saveName,
      sizeBytes: s.sizeBytes,
      sha256: s.sha256,
      createdAt: s.createdAt.subtract(d),
      updatedAt: s.updatedAt.subtract(d),
    );
  }
}

void main() {
  late Directory tmp;
  late String filesDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gp_save_sync');
    filesDir = tmp.path;
    final saves = Directory('$filesDir/saves')..createSync(recursive: true);
    File('${saves.path}/AABBCCDD.sav').writeAsBytesSync(List.filled(120, 1));
    File('${saves.path}/AABBCCDD.state').writeAsBytesSync(List.filled(64, 2));
    File('${saves.path}/AABBCCDD.slot1.state')
        .writeAsBytesSync(List.filled(80, 3));
    File('${saves.path}/AABBCCDD.slot1.jpg').writeAsBytesSync(List.filled(9, 4));
    // 应被忽略的噪声
    File('${saves.path}/11223344.sav').writeAsBytesSync([]);
    File('${saves.path}/11223344.preplay').writeAsBytesSync([1, 2, 3]);
    File('${saves.path}/kof97.state').writeAsBytesSync([1]);
    File('${saves.path}/AABBCCDD.slot1.state.part').writeAsBytesSync([9]);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('命名规约', () {
    test('nameFor 覆盖四种形态', () {
      expect(CloudSaveSync.nameFor(const SaveKey('aabbccdd', SaveKind.battery)),
          'AABBCCDD.sav');
      expect(CloudSaveSync.nameFor(const SaveKey('AABBCCDD', SaveKind.auto)),
          'AABBCCDD.state');
      expect(
          CloudSaveSync.nameFor(const SaveKey('AABBCCDD', SaveKind.slot, 2)),
          'AABBCCDD.slot2.state');
      expect(
          CloudSaveSync.nameFor(const SaveKey('AABBCCDD', SaveKind.slot, 2),
              isThumb: true),
          'AABBCCDD.slot2.thumb.dat');
    });

    test('parseCloudName 与 nameFor 互逆', () {
      const keys = [
        SaveKey('AABBCCDD', SaveKind.battery),
        SaveKey('AABBCCDD', SaveKind.auto),
        SaveKey('AABBCCDD', SaveKind.slot, 1),
        SaveKey('00FF00FF', SaveKind.slot, 12),
      ];
      for (final k in keys) {
        final p = CloudSaveSync.parseCloudName(CloudSaveSync.nameFor(k))!;
        expect(p.key, k);
        expect(p.isThumb, isFalse);
        if (k.kind != SaveKind.slot) continue; // 只有槽位有缩略图
        final t = CloudSaveSync
            .parseCloudName(CloudSaveSync.nameFor(k, isThumb: true))!;
        expect(t.key, k);
        expect(t.isThumb, isTrue);
      }
    });

    test('非本层命名返回 null（库备份/街机存档）', () {
      expect(CloudSaveSync.parseCloudName('retroemupouch_backup_1.json'), isNull);
      expect(CloudSaveSync.parseCloudName('kof97.state'), isNull);
      expect(CloudSaveSync.parseCloudName('AABBCCDD.slot1.jpg'), isNull);
    });

    test('clientKey 稳定且缩略图/本体不撞键', () {
      const k = SaveKey('AABBCCDD', SaveKind.slot, 3);
      expect(CloudSaveSync.clientKeyFor(k), 'gp-save:AABBCCDD:slot:3');
      expect(CloudSaveSync.clientKeyFor(k, isThumb: true),
          'gp-save:AABBCCDD:slot:3:thumb');
      expect(
          CloudSaveSync.clientKeyFor(const SaveKey('AABBCCDD', SaveKind.battery)),
          'gp-save:AABBCCDD:battery');
    });
  });

  group('本地扫描', () {
    test('只收本层命名的存档，空 .sav 与噪声被忽略', () {
      final sync = CloudSaveSync(filesDir: filesDir, client: _FakeTransport());
      final local = sync.scanLocal();
      expect(local.map((e) => e.key.id).toList(), [
        'AABBCCDD:auto',
        'AABBCCDD:battery',
        'AABBCCDD:slot:1',
      ]);
      final slot = local.firstWhere((e) => e.key.kind == SaveKind.slot);
      expect(slot.thumb, isNotNull);
      expect(slot.thumb!.uri.pathSegments.last, 'AABBCCDD.slot1.jpg');
      final battery = local.firstWhere((e) => e.key.kind == SaveKind.battery);
      expect(battery.size, 120);
      expect(battery.thumb, isNull);
    });

    test('缺少 saves 目录时返回空列表', () {
      final empty = Directory.systemTemp.createTempSync('gp_save_empty');
      addTearDown(() => empty.deleteSync(recursive: true));
      final sync = CloudSaveSync(filesDir: empty.path, client: _FakeTransport());
      expect(sync.scanLocal(), isEmpty);
    });
  });

  group('云端列表与比对', () {
    test('listCloud 跳过库备份 JSON，并解析出 key', () async {
      final t = _FakeTransport();
      final now = DateTime.now();
      t.store['k1'] = CloudSaveSummary(
          id: '1',
          saveName: 'AABBCCDD.sav',
          sizeBytes: 10,
          sha256: 'a' * 64,
          createdAt: now,
          updatedAt: now);
      t.store['k2'] = CloudSaveSummary(
          id: '2',
          saveName: 'AABBCCDD.slot1.thumb.dat',
          sizeBytes: 5,
          sha256: 'b' * 64,
          createdAt: now,
          updatedAt: now);
      t.store['k3'] = CloudSaveSummary(
          id: '3',
          saveName: 'retroemupouch_backup_1.json',
          sizeBytes: 7,
          sha256: 'c' * 64,
          createdAt: now,
          updatedAt: now);
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      final cloud = await sync.listCloud();
      expect(cloud.length, 2);
      expect(cloud.where((c) => c.isThumb).length, 1);
    });

    test('diff 区分 localOnly / localNewer / inSync / cloudOnly', () async {
      final t = _FakeTransport();
      final now = DateTime.now();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);

      // 先全部上传 → 全部 inSync
      await sync.uploadLocal(passphrase: 'p');
      var local = sync.scanLocal();
      var cloud = await sync.listCloud();
      var d = sync.diff(local, cloud);
      expect(d.localOnly, isEmpty);
      expect(d.inSync.length, local.length);
      expect(d.cloudOnly, isEmpty);

      // 本地改一个 battery（mtime 推到很新）→ localNewer
      final batt = local.firstWhere((e) => e.key.kind == SaveKind.battery);
      batt.file.setLastModifiedSync(now.add(const Duration(minutes: 5)));
      local = sync.scanLocal();
      d = sync.diff(local, await sync.listCloud());
      expect(d.localNewer.map((e) => e.key.kind), [SaveKind.battery]);

      // 删掉本地 auto → cloudOnly
      final auto = local.firstWhere((e) => e.key.kind == SaveKind.auto);
      auto.file.deleteSync();
      local = sync.scanLocal();
      d = sync.diff(local, await sync.listCloud());
      expect(d.cloudOnly.map((e) => e.key.kind), [SaveKind.auto]);
      expect(d.pendingUpload, 1);
    });
  });

  group('上传', () {
    test('上传全部（含缩略图），clientKey 稳定', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      final progress = <String>[];
      final report = await sync.uploadLocal(
        passphrase: 'pw',
        onProgress: (done, total) => progress.add('$done/$total'),
      );
      expect(report.ok, 3);
      expect(report.hasError, isFalse);
      expect(t.calls.map((c) => c.saveName).toList()..sort(), [
        'AABBCCDD.sav',
        'AABBCCDD.slot1.state',
        'AABBCCDD.slot1.thumb.dat',
        'AABBCCDD.state',
      ]);
      expect(t.calls.map((c) => c.clientKey).toSet().length, 4);
      expect(progress.last, '4/4');

      // 再传一次：后端覆盖，云端条目数不增
      await sync.uploadLocal(passphrase: 'pw');
      expect(t.store.length, 4);
      expect((await sync.listCloud()).length, 4);
    });

    test('单个失败不影响其它条目，并记录失败项', () async {
      final t = _FakeTransport()..failWhenNameContains = 'slot1.thumb';
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      final report = await sync.uploadLocal(passphrase: 'pw');
      expect(report.ok, 3);
      expect(report.failed.length, 1);
      expect(report.failed.first.isThumb, isTrue);
      expect('${report.failed.first.error}', contains('boom'));
    });

    test('only 过滤只上传指定 key', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      final report = await sync.uploadLocal(
        passphrase: 'pw',
        only: const [SaveKey('AABBCCDD', SaveKind.battery)],
      );
      expect(report.ok, 1);
      expect(t.calls.single.saveName, 'AABBCCDD.sav');
    });

    test('includeThumbs=false 时不传缩略图', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      await sync.uploadLocal(passphrase: 'pw', includeThumbs: false);
      expect(t.calls.map((c) => c.saveName), isNot(contains(contains('thumb'))));
      expect(t.calls.length, 3);
    });
  });

  group('恢复', () {
    /// 上传全部 → 清空本地（模拟换机/重装）→ 返回 sync 与上传时的字节。
    Future<(CloudSaveSync, Map<String, List<int>>, _FakeTransport)>
        uploadThenWipe() async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      await sync.uploadLocal(passphrase: 'pw');
      final snapshot = {
        for (final e in sync.scanLocal()) e.fileName: e.file.readAsBytesSync(),
        'AABBCCDD.slot1.jpg': File('$filesDir/saves/AABBCCDD.slot1.jpg')
            .readAsBytesSync(),
      };
      for (final f in Directory('$filesDir/saves').listSync()) {
        if (f is File) f.deleteSync();
      }
      return (sync, snapshot, t);
    }

    test('云端独有 → 恢复出同名文件，内容逐字节一致', () async {
      final (sync, snapshot, _) = await uploadThenWipe();
      expect(sync.scanLocal(), isEmpty);

      final progress = <String>[];
      final report = await sync.restore(
        passphrase: 'pw',
        onProgress: (d, t) => progress.add('$d/$t'),
      );
      expect(report.ok, 3);
      expect(report.hasError, isFalse);
      expect(report.backups, isEmpty, reason: '本地本来没有文件，不该产生备份');
      expect(report.restored.length, 3);

      final restored = sync.scanLocal();
      expect(restored.length, 3);
      for (final l in restored) {
        expect(l.file.readAsBytesSync(), snapshot[l.fileName],
            reason: '${l.fileName} 内容必须与上传时一致');
      }
      // 缩略图也回来了
      final thumb = File('$filesDir/saves/AABBCCDD.slot1.jpg');
      expect(thumb.existsSync(), isTrue);
      expect(thumb.readAsBytesSync(), snapshot['AABBCCDD.slot1.jpg']);
      expect(progress.last, '4/4');
    });

    test('本地有更新的档 → 覆盖前生成 .bak 备份，原内容可回滚', () async {
      final (sync, _, _) = await uploadThenWipe();
      final dest = File('$filesDir/saves/AABBCCDD.sav');
      dest.writeAsBytesSync(List.filled(7, 9)); // 本地“更新但未上传”的版本

      final report = await sync.restore(
        passphrase: 'pw',
        items: (await sync.listCloud())
            .where((c) => c.key.kind == SaveKind.battery),
      );
      expect(report.ok, 1);
      expect(report.backups.length, 1);
      final bak = report.backups.single;
      expect(bak.readAsBytesSync(), List.filled(7, 9), reason: '备份必须是旧内容');
      expect(dest.readAsBytesSync(), isNot(List.filled(7, 9)));
      expect(dest.lengthSync(), 120);
    });

    test('下载失败 → 本地原档不被破坏，且不留 .part', () async {
      final (sync, _, t) = await uploadThenWipe();
      final dest = File('$filesDir/saves/AABBCCDD.state');
      final keep = List.filled(11, 5);
      dest.writeAsBytesSync(keep);

      final cloud = await sync.listCloud();
      final auto = cloud.firstWhere((c) => c.key.kind == SaveKind.auto);
      t.failDownloadIds.add(auto.id);

      final report = await sync.restore(passphrase: 'pw', items: [auto]);
      expect(report.ok, 0);
      expect(report.failed.length, 1);
      expect(dest.readAsBytesSync(), keep, reason: '失败时本地必须原样保留');
      expect(File('${dest.path}.part').existsSync(), isFalse);
    });

    test('includeThumbs=false 只恢复本体', () async {
      final (sync, _, _) = await uploadThenWipe();
      final report = await sync.restore(passphrase: 'pw', includeThumbs: false);
      expect(report.ok, 3);
      expect(File('$filesDir/saves/AABBCCDD.slot1.jpg').existsSync(), isFalse);
      expect(File('$filesDir/saves/AABBCCDD.slot1.state').existsSync(), isTrue);
    });

    test('同一槽位多份云端条目时只取最新一份', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      final src = File('$filesDir/saves/AABBCCDD.sav');
      // 用不同 clientKey 造两份“同槽位”上传（现实里是别的设备/旧版本）
      await sync.uploadLocal(
          passphrase: 'pw', only: const [SaveKey('AABBCCDD', SaveKind.battery)]);
      src.writeAsBytesSync(List.filled(33, 3));
      await t.uploadSave(
        saveName: 'AABBCCDD.sav',
        clientKey: 'other-device',
        file: src,
        passphrase: 'pw',
      );
      src.deleteSync();

      final report = await sync.restore(passphrase: 'pw');
      expect(report.restored.length, 1, reason: '同一槽位只恢复一份');
      expect(src.lengthSync(), 33, reason: '应取最新上传的那份');
    });
  });

  group('冲突决策', () {
    test('本地较新 → 上传后 diff 归零', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      await sync.uploadLocal(passphrase: 'pw');
      // 云端停在 10 分钟前（= 本地上次同步后又改过），本地 mtime 仍是刚才
      t.age('gp-save:AABBCCDD:battery', const Duration(minutes: 10));

      var d = sync.diff(sync.scanLocal(), await sync.listCloud());
      expect(d.localNewer.length, 1);
      expect(d.pendingUpload, 1);
      expect(d.isClean, isFalse);

      // 决策 = 保留本地 → 上传覆盖云端
      await sync.uploadLocal(
          passphrase: 'pw', only: [d.localNewer.single.key]);
      d = sync.diff(sync.scanLocal(), await sync.listCloud());
      expect(d.isClean, isTrue, reason: '上传后不应再有待处理项');
    });

    test('云端较新 → 恢复后 mtime 对齐云端，不再判冲突且留 .bak', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      await sync.uploadLocal(passphrase: 'pw');

      // 模拟“别的设备在我这个文件之后上传过”：本地 mtime 推到 10 分钟前
      final batt = File('$filesDir/saves/AABBCCDD.sav');
      final oldBytes = List<int>.filled(120, 42);
      batt.writeAsBytesSync(oldBytes);
      batt.setLastModifiedSync(
          DateTime.now().subtract(const Duration(minutes: 10)));

      var d = sync.diff(sync.scanLocal(), await sync.listCloud());
      expect(d.remoteNewer.length, 1);
      expect(d.remoteNewer.single.local.fileName, 'AABBCCDD.sav');
      expect(d.pendingDownload, 1);

      final r = await sync.restore(
          passphrase: 'pw', items: [d.remoteNewer.single.cloud]);
      expect(r.ok, 1);
      expect(r.backups.length, 1, reason: '覆盖本地前必须备份');
      expect(r.backups.single.readAsBytesSync(), oldBytes);

      d = sync.diff(sync.scanLocal(), await sync.listCloud());
      expect(d.isClean, isTrue, reason: '恢复后 mtime 应与云端对齐，不再算冲突');
      expect(batt.readAsBytesSync(), isNot(oldBytes));
      // 落盘文件的 mtime 应等于云端 updated_at（±3s 容差内）
      final cloud = (await sync.listCloud())
          .firstWhere((c) => c.key.kind == SaveKind.battery);
      expect(
        batt.lastModifiedSync().difference(cloud.updatedAt).inSeconds.abs() <= 3,
        isTrue,
      );
    });

    test('云端独有（cloudOnly）恢复后变为已同步', () async {
      final t = _FakeTransport();
      final sync = CloudSaveSync(filesDir: filesDir, client: t);
      await sync.uploadLocal(passphrase: 'pw');
      // 删掉本地 auto，模拟“换机后只拿到部分文件”
      File('$filesDir/saves/AABBCCDD.state').deleteSync();

      var d = sync.diff(sync.scanLocal(), await sync.listCloud());
      expect(d.cloudOnly.map((c) => c.key.kind), [SaveKind.auto]);
      expect(d.pendingDownload, 1);

      await sync.restore(passphrase: 'pw', items: d.cloudOnly);
      d = sync.diff(sync.scanLocal(), await sync.listCloud());
      expect(d.isClean, isTrue);
    });
  });
}
