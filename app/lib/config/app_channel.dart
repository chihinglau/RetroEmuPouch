/// Compiled-in distribution channel.
///
/// Set at build time via `--dart-define=CHANNEL=store|community`, matching the
/// Gradle `productFlavors` in `app/android/app/build.gradle.kts`. The two MUST
/// agree or the runtime behaviour (self-update, ROM download, cleartext LAN)
/// will not match the signed binary that was reviewed for the store.
///
/// The default is `store` (the strict variant) so that a forgotten
/// `--dart-define` can never accidentally enable capabilities that are
/// prohibited in app-store distribution (in-app APK install, cloud ROM
/// download, plaintext LAN traffic). See remediation plan P0-1b.
enum AppChannel { store, community }

const AppChannel appChannel =
    String.fromEnvironment('CHANNEL', defaultValue: 'store') == 'community'
        ? AppChannel.community
        : AppChannel.store;

extension AppChannelX on AppChannel {
  bool get isStore => this == AppChannel.store;
  bool get isCommunity => this == AppChannel.community;

  /// R4: store channels forbid in-app APK installation / self-update.
  bool get canSelfUpdate => isCommunity;

  /// R1: store channels forbid cloud ROM download; users import locally.
  bool get canCloudRom => isCommunity;

  /// Point-to-point partner ROM transfer (「发现伙伴」→ 导入伙伴文件库).
  ///
  /// Deliberately kept separate from [canCloudRom]: R1 bans fetching ROMs from
  /// the *cloud* (server-mediated distribution), whereas this is a direct LAN
  /// transfer the user already possesses, with no server involvement — so it is
  /// permitted on store too. It is instead gated at runtime by an explicit
  /// compliance acknowledgement that must be confirmed before every transfer.
  bool get canPeerRom => true;
}
