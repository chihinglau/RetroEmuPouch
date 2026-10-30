import 'dart:io';

import 'ohos_pal.dart';
import 'platform_pal.dart';

/// Returns the platform-appropriate [PlatformPal] implementation.
///
/// We detect OpenHarmony via `Platform.operatingSystem == 'ohos'` rather than
/// `defaultTargetPlatform == TargetPlatform.ohos` **on purpose**: `TargetPlatform.ohos`
/// only exists in the OHOS flutter fork. The Android toolchain (stock Flutter
/// 3.47) does not define that enum value, so referencing it here would break the
/// Android build. The `Platform.operatingSystem` string check compiles under both
/// toolchains and is inert on Android (it is `'android'` there).
PlatformPal createPlatformPal() {
  if (Platform.operatingSystem == 'ohos') {
    return OhosPal();
  }
  return AndroidPal();
}
