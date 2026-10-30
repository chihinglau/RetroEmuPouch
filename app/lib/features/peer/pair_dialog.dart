import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/peer/peer_client.dart';
import '../../data/peer/peer_crypto.dart';
import '../../data/peer/peer_server.dart';
import '../../data/peer/peer_store.dart';

/// Result of the initiator pairing dialog.
class InitiatorPairResult {
  InitiatorPairResult({
    required this.ok,
    this.cancelled = false,
    this.deviceId,
    this.name,
    this.outboundToken,
    this.remoteToken,
    this.message,
  });

  final bool ok;
  final bool cancelled;
  final String? deviceId;
  final String? name;

  /// tokenA: minted by us, presented by our [PeerClient] to the partner.
  final String? outboundToken;

  /// tokenB: returned by the partner, stored as their inbound credential.
  final String? remoteToken;
  final String? message;
}

/// 6-digit code shown huge and grouped as `042 917` for readability.
String _groupCode(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

/// Initiator (A) side of the pairing handshake. Generates the code and
/// tokenA, posts /pair/start, then long-polls /pair/confirm after its human
/// confirms the code.
class InitiatorPairDialog extends StatefulWidget {
  const InitiatorPairDialog({
    super.key,
    required this.client,
    required this.selfName,
    required this.peerName,
  });

  final PeerClient client;
  final String selfName;
  final String peerName;

  @override
  State<InitiatorPairDialog> createState() => _InitiatorPairDialogState();

  static Future<InitiatorPairResult?> show(
    BuildContext context, {
    required PeerClient client,
    required String selfName,
    required String peerName,
  }) {
    return showDialog<InitiatorPairResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InitiatorPairDialog(
        client: client,
        selfName: selfName,
        peerName: peerName,
      ),
    );
  }
}

class _InitiatorPairDialogState extends State<InitiatorPairDialog> {
  late final String _pairId = PeerCrypto.randomHex(16);
  late final String _code = PeerCrypto.pairingCode();
  late final String _tokenA = PeerCrypto.randomHex(32);

  var _phase = _Phase.starting; // starting | code | waiting | error
  String? _error;
  int _ttlMs = 120000;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    try {
      _ttlMs = await widget.client.startPair(
        pairId: _pairId,
        code: _code,
        selfName: widget.selfName,
        tokenA: _tokenA,
      );
      if (!mounted) {
        return;
      }
      setState(() => _phase = _Phase.code);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _Phase.error;
        _error = '无法把配对请求发给对方：$e';
      });
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.client.cancelPair(_pairId);
    } catch (_) {/* best effort */}
    if (mounted) {
      Navigator.of(context).pop(InitiatorPairResult(
          ok: false,
          cancelled: true,
          outboundToken: _tokenA));
    }
  }

  Future<void> _confirmAndPoll() async {
    setState(() => _phase = _Phase.waiting);
    final deadline = DateTime.now().add(Duration(milliseconds: _ttlMs - 2000));
    String? failMessage;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r =
            await widget.client.confirmPair(pairId: _pairId, code: _code);
        if (!mounted) {
          return;
        }
        Navigator.of(context).pop(InitiatorPairResult(
          ok: true,
          deviceId: r.deviceId,
          name: r.name,
          remoteToken: r.token,
          outboundToken: _tokenA,
        ));
        return;
      } on PeerApiException catch (e) {
        if (e.responderPending) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        failMessage = switch (e.code) {
          'cancelled' => '对方取消了配对',
          'expired' => '配对已超时，请重新发起',
          'too_many_attempts' => '错误次数过多，该配对已失效',
          'unknown_session' => '配对会话不存在或已失效',
          _ => '配对失败（${e.code}）',
        };
        break;
      } catch (e) {
        failMessage = '网络异常：$e';
        break;
      }
    }
    if (!mounted) return;
    if (failMessage == null) {
      try {
        await widget.client.cancelPair(_pairId);
      } catch (_) {/* best effort */}
      failMessage = '等待对方确认超时，请靠近后重试';
    }
    setState(() {
      _phase = _Phase.error;
      _error = failMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.password, size: 20),
                const SizedBox(width: 8),
                Text('与「${widget.peerName}」配对',
                    style: Theme.of(context).textTheme.titleSmall),
              ]),
              const SizedBox(height: 14),
              if (_phase == _Phase.starting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_phase == _Phase.error) ...[
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 40),
                const SizedBox(height: 10),
                Text(_error ?? '配对失败', textAlign: TextAlign.center),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                      InitiatorPairResult(
                          ok: false, message: _error, outboundToken: _tokenA)),
                  child: const Text('关闭'),
                ),
              ] else ...[
                const Text('请与对方核对两台手机上的 6 位数字完全一致：',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    _groupCode(_code),
                    style: const TextStyle(
                      fontSize: 46,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (_phase == _Phase.code) ...[
                  FilledButton.icon(
                    onPressed: _confirmAndPoll,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('码一致，确认连接'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _cancel,
                    child: const Text('取消'),
                  ),
                ] else ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 10),
                  const Text('正在等待对方确认…', textAlign: TextAlign.center),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: _cancel,
                    child: const Text('取消配对'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Responder (B) side. Shows the same code and the initiator's name; local
/// confirmation opens the gate, then the dialog waits until our own store
/// receives the partner record (success) or the session ends.
class ResponderPairDialog extends StatefulWidget {
  const ResponderPairDialog({
    super.key,
    required this.request,
    required this.server,
    required this.store,
  });

  final PeerPairRequest request;
  final PeerServer server;
  final PeerStore store;

  @override
  State<ResponderPairDialog> createState() => _ResponderPairDialogState();

  /// True when pairing completed (record present), false on reject/end.
  static Future<bool?> show(
    BuildContext context, {
    required PeerPairRequest request,
    required PeerServer server,
    required PeerStore store,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ResponderPairDialog(
        request: request,
        server: server,
        store: store,
      ),
    );
  }
}

class _ResponderPairDialogState extends State<ResponderPairDialog> {
  var _phase = _Phase.code;
  String? _error;
  StreamSubscription<String>? _endSub;
  Timer? _watchdog;

  /// Credential fingerprint captured before this session existed. The dialog
  /// can be opened while a STALE record of the initiator is still present
  /// (the partner unpaired on their side, but we never learned about it):
  /// such an unchanged record must not be read as "this pairing succeeded".
  /// Completion requires the record to appear (fresh pairing) or its tokens
  /// to rotate (re-pairing overwrites via PeerStore.upsert).
  String? _priorFingerprint;

  String? _fingerprint(String deviceId) {
    final r = widget.store.get(deviceId);
    if (r == null) return null;
    return '${r.token}|${r.outboundToken ?? ''}';
  }

  bool get _committed {
    final id = widget.request.initiatorId;
    return widget.store.get(id) != null &&
        _fingerprint(id) != _priorFingerprint;
  }

  @override
  void initState() {
    super.initState();
    _priorFingerprint = _fingerprint(widget.request.initiatorId);
    _endSub = widget.server.pairSessionEnded.listen((pairId) {
      if (pairId != widget.request.pairId) return;
      // Success path removes the session too; a fresh/rotated store record
      // is the distinguishing signal (a stale record from a previous
      // pairing has the same fingerprint and must not count).
      if (_committed) {
        _finish(true);
      } else {
        _fail('对方取消了配对或会话已超时');
      }
    });
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_committed) {
        _finish(true);
      } else if (DateTime.now().isAfter(widget.request.expiresAt)) {
        _fail('配对已超时（2 分钟）');
      }
    });
  }

  @override
  void dispose() {
    _endSub?.cancel();
    _watchdog?.cancel();
    super.dispose();
  }

  void _finish(bool ok) {
    if (mounted) Navigator.of(context).pop(ok);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _error = message;
    });
  }

  void _confirm() {
    widget.server.responderConfirmed(widget.request.pairId);
    setState(() => _phase = _Phase.waiting);
  }

  void _reject() {
    widget.server.responderRejected(widget.request.pairId);
    _finish(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.devices_other, size: 20),
                const SizedBox(width: 8),
                Text('${widget.request.initiatorName} 请求配对',
                    style: Theme.of(context).textTheme.titleSmall),
              ]),
              const SizedBox(height: 14),
              if (_phase == _Phase.error) ...[
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 40),
                const SizedBox(height: 10),
                Text(_error ?? '配对已结束', textAlign: TextAlign.center),
                const SizedBox(height: 14),
                FilledButton(
                    onPressed: () => _finish(false), child: const Text('关闭')),
              ] else ...[
                const Text('请核对两台手机上的 6 位数字完全一致：',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    _groupCode(widget.request.code),
                    style: const TextStyle(
                      fontSize: 46,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (_phase == _Phase.code) ...[
                  FilledButton.icon(
                    onPressed: _confirm,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('码一致，确认连接'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _reject,
                    child: const Text('拒绝'),
                  ),
                ] else ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 10),
                  const Text('已确认，正在等待对方点击确认…',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: _reject,
                    child: const Text('取消配对'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _Phase { starting, code, waiting, error }
