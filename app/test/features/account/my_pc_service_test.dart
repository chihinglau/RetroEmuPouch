import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/data/peer/peer_store.dart';
import 'package:retroemupouch/features/account/my_pc_service.dart';

void main() {
  group('MyPc readiness', () {
    test('ready only when ip, port and outbound token are present', () {
      final full = PeerRecord(
        deviceId: 'pc-1',
        name: 'My PC',
        token: 'a' * 64,
        pairedAt: DateTime.now(),
        outboundToken: 'b' * 64,
        lastIp: '192.168.1.5',
        lastHttpPort: 43210,
      );
      final pc = MyPc(full);
      expect(pc.ready, isTrue);
      expect(pc.baseUrl, 'http://192.168.1.5:43210');

      expect(
          MyPc(PeerRecord(
            deviceId: 'x',
            name: 'n',
            token: 't' * 64,
            pairedAt: DateTime.now(),
          )).ready,
          isFalse);
    });
  });

  group('saveCrc', () {
    test('parses battery / auto / slot saves, ignores others', () {
      expect(MyPcService.saveCrc('ABCD1234.sav'), 'ABCD1234');
      expect(MyPcService.saveCrc('abcd1234.state'), 'ABCD1234');
      expect(MyPcService.saveCrc('0123ABCD.slot3.state'), '0123ABCD');
      expect(MyPcService.saveCrc('ABCD1234.slot1.jpg'), isNull);
      expect(MyPcService.saveCrc('notes.txt'), isNull);
    });
  });

  group('MyPcService.list (offline read path)', () {
    test('reads paired PCs from PeerStore in filesDir', () async {
      final dir = await Directory.systemTemp.createTemp('mypc_');
      final peersFile = File('${dir.path}/library/peers.json');
      await peersFile.create(recursive: true);
      await peersFile.writeAsString('{"version":1,"peers":['
          '{"deviceId":"pc-1","name":"Desk","token":"${'a' * 64}",'
          '"pairedAt":"2026-01-01T00:00:00.000Z",'
          '"outboundToken":"${'b' * 64}","lastIp":"10.0.0.2",'
          '"lastHttpPort":1234}]}');
      final store = await PeerStore.load(dir.path);
      final pcs = store.list.map(MyPc.new).toList();
      expect(pcs, hasLength(1));
      expect(pcs.first.name, 'Desk');
      expect(pcs.first.ready, isTrue);
    });
  });
}
