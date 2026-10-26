import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/services/reporter_handle_registration.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _key = Uint8List.fromList(List<int>.generate(32, (i) => i));

void main() {
  late List<(String uid, String handle, Map<String, Object> fields)> writes;
  late Future<void> Function() remote;
  late Future<Uint8List?> Function() signingKey;
  late ReporterHandleRegistration registration;

  setUp(() {
    SharedPreferences.setMockInitialValues({'broadcast_handle': '0a1b2c3d4e5f'});
    writes = [];
    remote = () async {};
    signingKey = () async => _key;
    registration = ReporterHandleRegistration(
      writeRemote: (uid, handle, fields) {
        writes.add((uid, handle, fields));
        return remote();
      },
      loadSigningPublicKey: () => signingKey(),
    );
  });

  group('registering the Reporter Handle (#110)', () {
    test('signed in: this installation\'s Handle and signing key go under the uid', () async {
      await registration.register('uid-1');

      expect(writes, hasLength(1));
      final (uid, handle, fields) = writes.single;
      expect(uid, 'uid-1');
      expect(handle, '0a1b2c3d4e5f', reason: 'the document ID is the stored Reporter Handle');
      expect(fields, {
        'reporterHandle': '0a1b2c3d4e5f',
        'signingPublicKey': Blob(_key),
        'registeredAt': FieldValue.serverTimestamp(),
      });
    });

    test('signed out: nothing is written and the key is not even asked for', () async {
      var keyAsked = false;
      signingKey = () async {
        keyAsked = true;
        return _key;
      };

      await registration.register(null);

      expect(writes, isEmpty);
      expect(keyAsked, isFalse);
    });

    test('a device without a Handle yet gets one, and it is the one registered', () async {
      SharedPreferences.setMockInitialValues({});

      await registration.register('uid-1');

      final stored = (await SharedPreferences.getInstance()).getString('broadcast_handle');
      expect(stored, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(writes.single.$2, stored);
      expect(writes.single.$3['reporterHandle'], stored);
    });

    test('registering again writes the same document again (idempotent)', () async {
      await registration.register('uid-1');
      await registration.register('uid-1');

      expect(writes.map((w) => (w.$1, w.$2)), [('uid-1', '0a1b2c3d4e5f'), ('uid-1', '0a1b2c3d4e5f')]);
    });

    test('a failing cloud write is swallowed, not thrown', () async {
      remote = () async => throw StateError('permission-denied');

      await expectLater(registration.register('uid-1'), completes);
      expect(writes, hasLength(1));
    });

    test('a cloud write that throws before returning a future is swallowed too', () async {
      registration = ReporterHandleRegistration(
        writeRemote: (uid, handle, fields) => throw StateError('no Firebase app'),
        loadSigningPublicKey: () => signingKey(),
      );

      await expectLater(registration.register('uid-1'), completes);
    });

    final unavailableKeys = <String, Future<Uint8List?> Function()>{
      'the mesh service is not there yet': () async =>
          throw PlatformException(code: 'SERVICE_NOT_READY', message: 'Mesh service is not running'),
      'there is no native mesh on this platform': () async => throw MissingPluginException('no native'),
      'native answers no key': () async => null,
      'native answers a key that is not 32 bytes': () async => Uint8List(31),
    };
    for (final MapEntry(key: situation, value: key) in unavailableKeys.entries) {
      test('skipped quietly when $situation', () async {
        signingKey = key;

        await expectLater(registration.register('uid-1'), completes);
        expect(writes, isEmpty);
      });
    }
  });

  group('when it registers', () {
    late StreamController<String?> authState;
    late List<String> registered;
    late StreamSubscription<String?> subscription;

    setUp(() {
      authState = StreamController<String?>();
      registered = [];
    });

    tearDown(() async {
      await subscription.cancel();
      await authState.close();
    });

    test('at start for the signed-in uid, then again after each later sign-in', () async {
      subscription = registerReporterHandleOnSignIn(authState.stream, (uid) async => registered.add(uid));

      authState.add('uid-1'); // App start, already signed in.
      await pumpEventQueue();
      expect(registered, ['uid-1']);

      authState.add(null); // Signed out.
      await pumpEventQueue();
      expect(registered, ['uid-1'], reason: 'never for a signed-out phone');

      authState.add('uid-2'); // Signed in again, possibly as someone else.
      await pumpEventQueue();
      expect(registered, ['uid-1', 'uid-2']);
    });

    test('never for a phone that starts signed out', () async {
      subscription = registerReporterHandleOnSignIn(authState.stream, (uid) async => registered.add(uid));

      authState.add(null);
      await pumpEventQueue();

      expect(registered, isEmpty);
    });

    test('an error in the sign-in state does not escape and later sign-ins still register', () async {
      subscription = registerReporterHandleOnSignIn(authState.stream, (uid) async => registered.add(uid));

      authState.addError(StateError('auth unavailable'));
      authState.add('uid-1');
      await pumpEventQueue();

      expect(registered, ['uid-1']);
    });

    test('a registration that fails does not escape and the next sign-in still registers', () async {
      var calls = 0;
      subscription = registerReporterHandleOnSignIn(authState.stream, (uid) {
        calls++;
        if (calls == 1) throw StateError('thrown at once');
        if (calls == 2) return Future.error(StateError('failed later'));
        registered.add(uid);
        return Future.value();
      });

      authState
        ..add('uid-1')
        ..add('uid-1')
        ..add('uid-1');
      await pumpEventQueue();

      expect(calls, 3);
      expect(registered, ['uid-1']);
    });

    test('drives the real registration: written for the signed-in uid only', () async {
      subscription = registerReporterHandleOnSignIn(authState.stream, registration.register);

      authState
        ..add('uid-1')
        ..add(null);
      await pumpEventQueue();

      expect(writes.map((w) => w.$1), ['uid-1']);
    });
  });
}
