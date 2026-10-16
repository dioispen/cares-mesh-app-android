import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/user.dart';
import 'package:flutter_ui/services/profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppUser _user({String name = '王小明', String? bloodType = 'O 型', String? photo}) => AppUser(
      id: 'uid-1',
      email: 'a@example.com',
      name: name,
      phone: '0912-345-678',
      area: '南投縣埔里鎮',
      emergencyContactName: '王大明',
      emergencyContactPhone: '0923-456-789',
      emergencyContactRelation: '父親',
      bloodType: bloodType,
      medicalInfo: null,
      registeredAt: DateTime.utc(2026, 1, 2),
      avatar: photo == null ? 'cat' : 'photo',
      avatarPhoto: photo,
    );

void main() {
  late List<(String, Map<String, Object?>)> writes;
  late Completer<void> remote;
  late ProfileStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    writes = [];
    remote = Completer<void>();
    store = ProfileStore(writeRemote: (uid, fields) {
      writes.add((uid, fields));
      return remote.future;
    });
  });

  Future<AppUser?> stored() async {
    final raw = (await SharedPreferences.getInstance()).getString('app_user');
    return raw == null ? null : AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  test('saving the profile writes it on this device before the cloud answers', () async {
    final sync = (await store.saveProfile(_user(name: '王小華'))).synced;

    expect((await stored())?.name, '王小華');
    var synced = false;
    unawaited(sync.then((_) => synced = true));
    await Future<void>.delayed(Duration.zero);
    expect(synced, isFalse, reason: 'still waiting for Firestore');

    remote.complete();
    await sync;
  });

  test('the cloud gets the editable fields of users/{uid}, a cleared one as null', () async {
    await store.saveProfile(_user(bloodType: null));

    expect(writes.map((w) => w.$1), ['uid-1']);
    expect(writes.single.$2, {
          'name': '王小明',
          'phone': '0912-345-678',
          'area': '南投縣埔里鎮',
          'emergencyContactName': '王大明',
          'emergencyContactPhone': '0923-456-789',
          'emergencyContactRelation': '父親',
          'bloodType': null,
          'medicalInfo': null,
        });
  });

  test('a cloud failure reaches the caller; the device copy stays', () async {
    final sync = (await store.saveProfile(_user(name: '王小華'))).synced;
    remote.completeError(StateError('permission-denied'));

    await expectLater(sync, throwsStateError);
    expect((await stored())?.name, '王小華');
  });

  test('saving the avatar writes only the avatar, dropping an old photo', () async {
    await store.saveAvatar(_user());

    expect(writes.map((w) => w.$1), ['uid-1']);
    expect(writes.single.$2, {'avatar': 'cat', 'avatarPhoto': null});
    expect((await stored())?.avatar, 'cat');
  });

  test('loads what was saved', () async {
    expect(await store.load(), isNull);

    await store.saveAvatar(_user(photo: 'base64'));

    expect((await store.load())?.avatarPhoto, 'base64');
  });
}
