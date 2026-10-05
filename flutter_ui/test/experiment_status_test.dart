import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/bridge/bitchat_bridge.dart' show ExperimentErrors;
import 'package:flutter_ui/models/experiment_status.dart';

/// A SenderStatus map exactly as the Kotlin experiment bridge sends it.
Map<Object?, Object?> _sender({
  String state = 'sending',
  int sent = 12,
  int failed = 1,
  int written = 9,
  int noLink = 2,
  int total = 50,
  int? startsAtMs = 1700000000000,
  String? handle = 'ee0000000003',
  int? ttl = 7,
  int? intervalMs = 200,
  bool? keepAwake = true,
}) =>
    {
      'state': state,
      'sent': sent,
      'failed': failed,
      'written': written,
      'noLink': noLink,
      'total': total,
      'startsAtMs': startsAtMs,
      'handle': handle,
      'ttl': ttl,
      'intervalMs': intervalMs,
      'keepAwake': keepAwake,
    };

/// An `experiment_getStatus` reply exactly as the Kotlin experiment bridge sends it.
Map<Object?, Object?> _status() => {
      'links': 2,
      'powerMode': 'BALANCED',
      'systemPowerSave': true,
      'peerId': 'a1b2c3d4',
      'rx20s': <Object?, Object?>{'ee0000000001': 4},
      'rx60s': <Object?, Object?>{'ee0000000001': 9, 'ee0000000002': 1},
      'sender': _sender(),
    };

void main() {
  group('ExperimentHandles', () {
    test('device N sends with the fixed handle: ee, then N zero-padded to 10 digits', () {
      expect(ExperimentHandles.forDevice(1), 'ee0000000001');
      expect(ExperimentHandles.forDevice(7), 'ee0000000007');
      expect(ExperimentHandles.forDevice(10), 'ee0000000010');
      expect(ExperimentHandles.forDevice(3).length, 12);
    });

    test('lists the ten devices in order', () {
      expect(ExperimentHandles.devices, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(ExperimentHandles.all, [
        'ee0000000001',
        'ee0000000002',
        'ee0000000003',
        'ee0000000004',
        'ee0000000005',
        'ee0000000006',
        'ee0000000007',
        'ee0000000008',
        'ee0000000009',
        'ee0000000010',
      ]);
    });
  });

  group('ExperimentSenderStatus.fromMap', () {
    test('reads every bridge field', () {
      final sender = ExperimentSenderStatus.fromMap(_sender())!;

      expect(sender.state, ExperimentSenderState.sending);
      expect(sender.sent, 12);
      expect(sender.failed, 1);
      expect(sender.written, 9);
      expect(sender.noLink, 2);
      expect(sender.total, 50);
      expect(sender.startsAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(sender.handle, 'ee0000000003');
      expect(sender.ttl, 7);
      expect(sender.intervalMs, 200);
      expect(sender.keepAwake, isTrue);
    });

    test('reads each state; an unknown one is not mistaken for a known one', () {
      ExperimentSenderState state(Object? wire) => ExperimentSenderStatus.fromMap(_sender()..['state'] = wire)!.state;

      expect(state('idle'), ExperimentSenderState.idle);
      expect(state('waiting'), ExperimentSenderState.waiting);
      expect(state('sending'), ExperimentSenderState.sending);
      expect(state('done'), ExperimentSenderState.done);
      expect(state('stopped'), ExperimentSenderState.stopped);
      expect(state('paused'), ExperimentSenderState.unknown);
      expect(state(null), ExperimentSenderState.unknown);
    });

    test('only waiting and sending count as running', () {
      expect(
        {for (final s in ExperimentSenderState.values) s: s.isRunning},
        {
          ExperimentSenderState.idle: false,
          ExperimentSenderState.waiting: true,
          ExperimentSenderState.sending: true,
          ExperimentSenderState.done: false,
          ExperimentSenderState.stopped: false,
          ExperimentSenderState.unknown: false,
        },
      );
    });

    test('an idle sender has no schedule', () {
      final sender = ExperimentSenderStatus.fromMap(
        _sender(state: 'idle', sent: 0, failed: 0, total: 0, startsAtMs: null, handle: null, ttl: null, intervalMs: null),
      )!;

      expect(sender.state, ExperimentSenderState.idle);
      expect(sender.startsAt, isNull);
      expect(sender.handle, isNull);
      expect(sender.ttl, isNull);
      expect(sender.intervalMs, isNull);
    });

    test('a field of the wrong type falls back instead of throwing', () {
      final sender = ExperimentSenderStatus.fromMap({
        'state': 'sending',
        'sent': '12',
        'failed': -1,
        'total': 1.5,
        'startsAtMs': 'soon',
        'handle': 3,
        'ttl': '7',
        'intervalMs': -5,
      })!;

      expect(sender.sent, 0);
      expect(sender.failed, 0);
      expect(sender.total, 0);
      expect(sender.startsAt, isNull);
      expect(sender.handle, isNull);
      expect(sender.ttl, isNull);
      expect(sender.intervalMs, isNull);
    });

    test('something that is not a map is not a sender status', () {
      expect(ExperimentSenderStatus.fromMap(null), isNull);
      expect(ExperimentSenderStatus.fromMap('idle'), isNull);
    });
  });

  group('ExperimentStatus.fromMap', () {
    test('reads every bridge field', () {
      final status = ExperimentStatus.fromMap(_status())!;

      expect(status.links, 2);
      expect(status.powerMode, 'BALANCED');
      expect(status.peerId, 'a1b2c3d4');
      expect(status.rx20s, {'ee0000000001': 4});
      expect(status.rx60s, {'ee0000000001': 9, 'ee0000000002': 1});
      expect(status.sender.state, ExperimentSenderState.sending);
      expect(status.sender.sent, 12);
    });

    test('a phone whose mesh is not running has no peer id', () {
      expect(ExperimentStatus.fromMap(_status()..['peerId'] = null)!.peerId, isNull);
    });

    test('missing or mistyped fields stay unknown instead of turning into zero', () {
      final status = ExperimentStatus.fromMap(<Object?, Object?>{'links': '2', 'powerMode': 3, 'peerId': ''})!;

      expect(status.links, isNull);
      expect(status.powerMode, isNull);
      expect(status.peerId, isNull);
      expect(status.rx20s, isEmpty);
      expect(status.rx60s, isEmpty);
      expect(status.sender.state, ExperimentSenderState.idle);
    });

    test('RX entries that are not handle -> count are skipped, the rest kept', () {
      final status = ExperimentStatus.fromMap(_status()
        ..['rx20s'] = <Object?, Object?>{'ee0000000001': 4, 'ee0000000002': '5', 3: 1, 'ee0000000004': -1}
        ..['rx60s'] = 'not a map')!;

      expect(status.rx20s, {'ee0000000001': 4});
      expect(status.rx60s, isEmpty);
    });

    test('the parsed RX maps cannot be changed', () {
      final status = ExperimentStatus.fromMap(_status())!;

      expect(() => status.rx20s['ee0000000005'] = 1, throwsUnsupportedError);
    });

    test('something that is not a map is not a status', () {
      expect(ExperimentStatus.fromMap(null), isNull);
      expect(ExperimentStatus.fromMap(const [1, 2]), isNull);
    });

    test('RX rows list all seven handles, then anything else native counted', () {
      final status = ExperimentStatus.fromMap(_status()
        ..['rx20s'] = <Object?, Object?>{'ee00000000ff': 1}
        ..['rx60s'] = <Object?, Object?>{'ee00000000aa': 2, 'ee0000000002': 3})!;

      expect(status.rxHandles, [...ExperimentHandles.all, 'ee00000000aa', 'ee00000000ff']);
    });
  });

  group('powerModeLabel', () {
    test('names each PowerManager mode in Chinese', () {
      expect(powerModeLabel('PERFORMANCE'), '效能');
      expect(powerModeLabel('BALANCED'), '平衡');
      expect(powerModeLabel('POWER_SAVER'), '省電');
      expect(powerModeLabel('ULTRA_LOW_POWER'), '極省電');
      expect(powerModeLabel('TURBO'), isNull);
    });
  });

  group('ExperimentSenderInput', () {
    test('a count is a whole number of at least 1', () {
      expect(ExperimentSenderInput.parseCount('50'), 50);
      expect(ExperimentSenderInput.parseCount(' 1 '), 1);
      expect(ExperimentSenderInput.parseCount('0'), isNull);
      expect(ExperimentSenderInput.parseCount('-3'), isNull);
      expect(ExperimentSenderInput.parseCount(''), isNull);
      expect(ExperimentSenderInput.parseCount('1.5'), isNull);
      expect(ExperimentSenderInput.parseCount('abc'), isNull);
    });

    test('an interval is a whole number of milliseconds, 0 allowed for bursts', () {
      expect(ExperimentSenderInput.parseIntervalMs('0'), 0);
      expect(ExperimentSenderInput.parseIntervalMs('1000'), 1000);
      expect(ExperimentSenderInput.parseIntervalMs('-1'), isNull);
      expect(ExperimentSenderInput.parseIntervalMs(''), isNull);
    });

    test('numbers that do not fit a 32-bit native int are refused', () {
      expect(ExperimentSenderInput.parseCount('2147483647'), 2147483647);
      expect(ExperimentSenderInput.parseCount('2147483648'), isNull);
      expect(ExperimentSenderInput.parseIntervalMs('99999999999999999999'), isNull);
    });

    test('an empty start time means start now', () {
      expect(ExperimentSenderInput.parseStartAt(''), (valid: true, startAt: null));
      expect(ExperimentSenderInput.parseStartAt('   '), (valid: true, startAt: null));
    });

    test('a start time is normalised to HH:mm:ss', () {
      expect(ExperimentSenderInput.parseStartAt('14:30:00'), (valid: true, startAt: '14:30:00'));
      expect(ExperimentSenderInput.parseStartAt('9:05:07'), (valid: true, startAt: '09:05:07'));
      expect(ExperimentSenderInput.parseStartAt(' 00:00:00 '), (valid: true, startAt: '00:00:00'));
      expect(ExperimentSenderInput.parseStartAt('23:59:59'), (valid: true, startAt: '23:59:59'));
      // A Chinese IME types the full-width colon.
      expect(ExperimentSenderInput.parseStartAt('14：30：00'), (valid: true, startAt: '14:30:00'));
    });

    test('anything else is not a start time', () {
      for (final text in ['24:00:00', '12:60:00', '12:00:60', '12:00', '120000', '12:0:00', 'noon', '-1:00:00']) {
        expect(ExperimentSenderInput.parseStartAt(text).valid, isFalse, reason: text);
      }
    });
  });

  group('the scheduled start as shown on screen', () {
    final now = DateTime(2026, 10, 4, 14, 0, 0);

    test('names the day so a start that rolled over to tomorrow is visible', () {
      expect(formatExperimentStart(DateTime(2026, 10, 4, 14, 30, 5), now), '今天 14:30:05');
      expect(formatExperimentStart(DateTime(2026, 10, 5, 9, 0, 0), now), '明天 09:00:00');
      expect(formatExperimentStart(DateTime(2026, 10, 3, 23, 59, 59), now), '昨天 23:59:59');
      expect(formatExperimentStart(DateTime(2026, 10, 7, 8, 1, 2), now), '2026-10-07 08:01:02');
    });

    test('isToday tells whether it starts today', () {
      expect(experimentStartsToday(DateTime(2026, 10, 4, 23, 59, 59), now), isTrue);
      expect(experimentStartsToday(DateTime(2026, 10, 5, 0, 0, 0), now), isFalse);
    });

    test('counts down to the start, rounded up to the second', () {
      expect(formatExperimentCountdown(DateTime(2026, 10, 4, 14, 0, 5), now), '0:00:05');
      expect(formatExperimentCountdown(DateTime(2026, 10, 4, 15, 2, 3), now), '1:02:03');
      expect(formatExperimentCountdown(DateTime(2026, 10, 5, 13, 59, 59), now), '23:59:59');
      expect(formatExperimentCountdown(now.add(const Duration(milliseconds: 1)), now), '0:00:01');
    });

    test('has no countdown once the start has passed', () {
      expect(formatExperimentCountdown(now, now), isNull);
      expect(formatExperimentCountdown(now.subtract(const Duration(seconds: 1)), now), isNull);
    });
  });

  group('experimentErrorReason', () {
    test('explains each native refusal in Chinese', () {
      expect(experimentErrorReason(PlatformException(code: ExperimentErrors.invalidArgument)), '參數不合法');
      expect(experimentErrorReason(PlatformException(code: ExperimentErrors.serviceNotReady)), 'mesh 服務未啟動');
      expect(experimentErrorReason(PlatformException(code: ExperimentErrors.alreadyRunning)), '發送器已在執行，請先停止');
    });

    test('an unknown code is shown as is', () {
      expect(experimentErrorReason(PlatformException(code: 'BOOM')), '原生錯誤（BOOM）');
    });

    test('a build without the native experiment tools says so', () {
      expect(experimentErrorReason(MissingPluginException()), '原生端沒有實驗工具（不是 debug build？）');
    });
  });

  group('the bridge fields added for the field-day bugs', () {
    test('the system battery saver is read as given, and anything but a bool is unknown', () {
      expect(ExperimentStatus.fromMap(_status())!.systemPowerSave, isTrue);
      expect(ExperimentStatus.fromMap(_status()..['systemPowerSave'] = false)!.systemPowerSave, isFalse);
      expect(ExperimentStatus.fromMap(_status()..['systemPowerSave'] = 'yes')!.systemPowerSave, isNull);
      expect(ExperimentStatus.fromMap(_status()..remove('systemPowerSave'))!.systemPowerSave, isNull);
    });

    test('write counts missing from an older native side read as 0', () {
      final sender = ExperimentSenderStatus.fromMap(_sender()..remove('written')..remove('noLink'))!;

      expect(sender.written, 0);
      expect(sender.noLink, 0);
    });
  });
}
