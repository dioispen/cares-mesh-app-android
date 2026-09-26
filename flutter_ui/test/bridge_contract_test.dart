// Source-level contracts of the Flutter ↔ Kotlin bridge that no single runtime test can see.
//
// `flutter test` runs with `flutter_ui/` as the working directory, so `lib/` is the Dart app and
// `../app/...` the Kotlin side of the same checkout.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _kotlinBridgeDir = '../app/src/main/java/com/bitchat/android/flutter';
const _dartBridge = 'lib/bridge/bitchat_bridge.dart';

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) fail('missing $path (run from flutter_ui/ inside the full checkout)');
  return file.readAsStringSync();
}

/// Method names the Kotlin bridge answers. `BitchatFlutterChannels.handle` matches string
/// literals; `ChatBridge.handle` matches `METHOD_*` constants. Everything else ends in
/// `notImplemented` (BridgeMethodDispatcher).
Set<String> _nativeMethods() {
  final channels = _read('$_kotlinBridgeDir/BitchatFlutterChannels.kt');
  final chat = _read('$_kotlinBridgeDir/ChatBridge.kt');

  final literalBranches = RegExp(r'^\s*"(\w+)"\s*->', multiLine: true)
      .allMatches(channels)
      .map((m) => m.group(1)!);

  final constants = {
    for (final m in RegExp(r'const val (METHOD_\w+) = "(\w+)"').allMatches(chat)) m.group(1)!: m.group(2)!,
  };
  final constantBranches = RegExp(r'^\s*(METHOD_\w+)\s*->', multiLine: true)
      .allMatches(chat)
      .map((m) => constants[m.group(1)!] ?? fail('ChatBridge branch ${m.group(1)} has no constant'));

  return {...literalBranches, ...constantBranches};
}

/// Method names `BitchatBridge` invokes, with `ChatMethods.x` resolved to its value.
Set<String> _dartInvokedMethods() {
  final source = _read(_dartBridge);

  final chatMethodsBlock =
      RegExp(r'abstract final class ChatMethods \{([^}]*)\}').firstMatch(source)?.group(1) ??
          fail('ChatMethods not found in $_dartBridge');
  final chatMethods = {
    for (final m in RegExp(r"static const (\w+) = '([^']+)';").allMatches(chatMethodsBlock))
      m.group(1)!: m.group(2)!,
  };

  final invoked = <String>{};
  for (final m in RegExp(r'\.invokeMethod(?:<[^>(]*>)?\(\s*([^,)\s]+)').allMatches(source)) {
    final argument = m.group(1)!;
    final literal = RegExp(r"^'([^']+)'$").firstMatch(argument);
    final constant = RegExp(r'^ChatMethods\.(\w+)$').firstMatch(argument);
    if (literal != null) {
      invoked.add(literal.group(1)!);
    } else if (constant != null) {
      invoked.add(chatMethods[constant.group(1)!] ?? fail('unknown ChatMethods.${constant.group(1)}'));
    } else {
      fail('cannot resolve the method name in invokeMethod($argument ...)');
    }
  }
  return invoked;
}

/// Dart files under `lib/`, as `lib/...` paths with forward slashes.
Map<String, String> _libSources() => {
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          entity.path.replaceAll(r'\', '/'): entity.readAsStringSync(),
    };

void main() {
  group('Dart only calls methods the native bridge implements (#12)', () {
    test('the source scan finds both sides', () {
      expect(_nativeMethods(), containsAll(['getSystemStatus', 'chat_sendMessage', 'chat_setNickname']));
      expect(_dartInvokedMethods(), containsAll(['getSystemStatus', 'chat_sendMessage', 'chat_setNickname']));
    });

    test('no Dart call falls through to notImplemented', () {
      final missing = _dartInvokedMethods().difference(_nativeMethods());

      expect(missing, isEmpty, reason: 'answered with notImplemented by BridgeMethodDispatcher');
    });

    test('the dead register / getProfile calls are gone', () {
      expect(_dartInvokedMethods(), isNot(anyOf(contains('register'), contains('getProfile'))));
    });
  });

  group('the mesh nickname is only written from the nickname editor (#52, ADR-0003)', () {
    // The chat screen's editor is the only UI that sets it; ChatService and BitchatBridge
    // just forward. Login, registration, e-mail verification and setup must never write it,
    // or an account's real name could end up broadcast in every ANNOUNCE.
    const writers = {
      'lib/bridge/bitchat_bridge.dart',
      'lib/services/chat_service.dart',
      'lib/screens/chat_screen.dart',
    };
    final writesNickname = RegExp(r'\bsetNickname\b|chat_setNickname');

    test('only the editor and its plumbing mention setNickname', () {
      final files = {
        for (final entry in _libSources().entries)
          if (writesNickname.hasMatch(entry.value)) entry.key,
      };

      expect(files, writers);
    });

    test('the account and setup flow never reach the nickname writer', () {
      final sources = _libSources();
      for (final path in const [
        'lib/main.dart',
        'lib/screens/setup_screen.dart',
        'lib/screens/login_screen.dart',
        'lib/screens/register_screen.dart',
        'lib/screens/verify_email_screen.dart',
        'lib/screens/onboarding_screen.dart',
        'lib/services/auth_service.dart',
      ]) {
        final source = sources[path] ?? fail('missing $path');
        expect(writesNickname.hasMatch(source), isFalse, reason: path);
      }
    });

    test('no nickname writer can see the account with its real name', () {
      final sources = _libSources();
      // Every place the real name lives: the AppUser model, its SharedPreferences copy, and
      // the Firebase account / Firestore profile.
      const routesToRealName = ['models/user.dart', "'app_user'", 'firebase_auth', 'cloud_firestore'];
      for (final path in writers) {
        for (final route in routesToRealName) {
          expect(sources[path], isNot(contains(route)), reason: '$path reaches $route');
        }
      }
    });
  });
}
