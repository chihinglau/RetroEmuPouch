import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/data/cloud/cloud_client.dart';

/// 后端 FastAPI 的错误体是 `{"detail": ...}`（部分历史接口是 `{"error": ...}`），
/// 客户端必须两种都认，否则用户只会看到「上传失败（400）」。
void main() {
  group('CloudClient.errorOf', () {
    test('识别 detail 字符串', () {
      expect(
        CloudClient.errorOf({'detail': 'cloud_save_requires_premium'}),
        '云存档需要会员',
      );
    });

    test('识别 error 字符串（兼容旧接口）', () {
      expect(CloudClient.errorOf({'error': 'network broken'}), 'network broken');
    });

    test('error 优先于 detail', () {
      expect(
        CloudClient.errorOf({'error': 'A', 'detail': 'B'}),
        'A',
      );
    });

    test('扩展名不允许时回显被拒扩展名', () {
      expect(
        CloudClient.errorOf({'detail': 'extension_not_allowed (got .zip)'}),
        '存档扩展名不允许（.zip）',
      );
    });

    test('已知错误码翻成中文', () {
      expect(CloudClient.errorOf({'detail': 'too_large'}), '存档超过 10MB 上限');
      expect(
        CloudClient.errorOf({'detail': 'blob_not_found'}),
        '云端存档不存在或已被删除',
      );
    });

    test('422 校验错误取首条 msg', () {
      expect(
        CloudClient.errorOf({
          'detail': [
            {'loc': ['body', 'save_name'], 'msg': 'field required'}
          ]
        }),
        'field required',
      );
    });

    test('未知形态返回 null（调用方回退为状态码提示）', () {
      expect(CloudClient.errorOf(null), isNull);
      expect(CloudClient.errorOf('boom'), isNull);
      expect(CloudClient.errorOf({'foo': 1}), isNull);
      expect(CloudClient.errorOf({'detail': ''}), isNull);
    });
  });
}
