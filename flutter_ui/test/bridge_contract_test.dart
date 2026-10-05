// Source-level contracts of the Flutter ↔ Kotlin bridge that no single runtime test can see.
//
// `flutter test` runs with `flutter_ui/` as the working directory, so `lib/` is the Dart app and
// `../app/...` the Kotlin side of the same checkout.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _kotlinBridgeDir = '../app/src/main/java/com/bitchat/android/flutter';

/// The experiment half of the bridge (#70). It lives in the debug source set only: release builds
/// answer its methods with `notImplemented`, which is fine because only the debug-only
/// `ExperimentScreen` calls them (checked below).
const _kotlinExperimentBridge = '../app/src/debug/java/com/bitchat/android/experiment/ExperimentBridge.kt';
const _dartBridge = 'lib/bridge/bitchat_bridge.dart';

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) fail('missing $path (run from flutter_ui/ inside the full checkout)');
  return file.readAsStringSync();
}

/// Method names a Kotlin bridge that declares them as `const val METHOD_X = "..."` matches in
/// `METHOD_X ->` branches.
Iterable<String> _constantBranches(String path) {
  final source = _read(path);
  final constants = {
    for (final m in RegExp(r'const val (METHOD_\w+) = "(\w+)"').allMatches(source)) m.group(1)!: m.group(2)!,
  };
  return RegExp(r'^\s*(METHOD_\w+)\s*->', multiLine: true)
      .allMatches(source)
      .map((m) => constants[m.group(1)!] ?? fail('$path: branch ${m.group(1)} has no constant'));
}

/// `ERROR_X` -> code of a Kotlin bridge that declares them as `const val ERROR_X = "..."`.
Map<String, String> _kotlinErrorCodes(String path) => {
      for (final m in RegExp(r'const val (ERROR_\w+) = "(\w+)"').allMatches(_read(path))) m.group(1)!: m.group(2)!,
    };

/// The codes listed in a Dart `abstract final class <name> { static const x = '...'; }`.
Set<String> _dartErrorCodes(String className) {
  final block = RegExp('abstract final class $className \\{([^}]*)\\}').firstMatch(_read(_dartBridge))?.group(1) ??
      fail('$className not found in $_dartBridge');
  return {for (final m in RegExp(r"static const \w+ = '([^']+)';").allMatches(block)) m.group(1)!};
}

/// Method names the Kotlin bridge answers. `BitchatFlutterChannels.handle` matches string
/// literals; `ChatBridge.handle` and the debug-only `ExperimentBridge.handle` match `METHOD_*`
/// constants. Everything else ends in `notImplemented` (BridgeMethodDispatcher).
Set<String> _nativeMethods() {
  final channels = _read('$_kotlinBridgeDir/BitchatFlutterChannels.kt');

  final literalBranches = RegExp(r'^\s*"(\w+)"\s*->', multiLine: true)
      .allMatches(channels)
      .map((m) => m.group(1)!);

  return {
    ...literalBranches,
    ..._constantBranches('$_kotlinBridgeDir/ChatBridge.kt'),
    ..._constantBranches(_kotlinExperimentBridge),
  };
}

/// Method names `BitchatBridge` invokes, with `ChatMethods.x` / `ExperimentMethods.x` resolved to
/// their values.
Set<String> _dartInvokedMethods() {
  final source = _read(_dartBridge);

  // `abstract final class XMethods { static const name = 'value'; ... }`, per class.
  final methodClasses = {
    for (final block in RegExp(r'abstract final class (\w+Methods) \{([^}]*)\}').allMatches(source))
      block.group(1)!: {
        for (final m in RegExp(r"static const (\w+) = '([^']+)';").allMatches(block.group(2)!)) m.group(1)!: m.group(2)!,
      },
  };
  for (final name in const ['ChatMethods', 'ExperimentMethods']) {
    if (!methodClasses.containsKey(name)) fail('$name not found in $_dartBridge');
  }

  final invoked = <String>{};
  for (final m in RegExp(r'\.invokeMethod(?:<[^>(]*>)?\(\s*([^,)\s]+)').allMatches(source)) {
    final argument = m.group(1)!;
    final literal = RegExp(r"^'([^']+)'$").firstMatch(argument);
    final constant = RegExp(r'^(\w+Methods)\.(\w+)$').firstMatch(argument);
    if (literal != null) {
      invoked.add(literal.group(1)!);
    } else if (constant != null) {
      final [className, name] = [constant.group(1)!, constant.group(2)!];
      invoked.add(methodClasses[className]?[name] ?? fail('unknown $className.$name'));
    } else {
      fail('cannot resolve the method name in invokeMethod($argument ...)');
    }
  }
  return invoked;
}

/// [source] with every full-line comment (`//`, `///`) blanked out, offsets and line numbers kept:
/// a name in a doc comment is not compiled. A trailing comment is left in, which can only make a
/// check stricter.
String _withoutCommentLines(String source) => source.replaceAllMapped(
      RegExp(r'^[ \t]*//.*$', multiLine: true),
      (m) => ' ' * m.group(0)!.length,
    );

/// The source ranges of the "debug" branch of every `kDebugMode ? <debug> : <release>` expression
/// in [source]. In a release build `kDebugMode` is the compile-time constant `false`, so nothing in
/// those ranges is compiled in.
///
/// A small scanner, not a parser: the branch ends at the first `:` outside any bracket and string.
/// A nested ternary in the branch only makes the range shorter, so it can make a check stricter,
/// never looser.
List<(int, int)> _debugOnlyRanges(String source) {
  final ranges = <(int, int)>[];
  for (final m in RegExp(r'\bkDebugMode\s*\?(?![?.])').allMatches(source)) {
    var depth = 0;
    var i = m.end;
    int? end;
    while (i < source.length && end == null) {
      final c = source[i];
      if (c == "'" || c == '"') {
        // Skip a string literal (with its escapes).
        i++;
        while (i < source.length && source[i] != c) {
          if (source[i] == r'\') i++;
          i++;
        }
      } else if (source.startsWith('//', i)) {
        i = source.indexOf('\n', i);
        if (i == -1) break;
      } else if ('([{'.contains(c)) {
        depth++;
      } else if (')]}'.contains(c)) {
        depth--;
        if (depth < 0) fail('kDebugMode ternary at ${m.start} has no ":" before its expression ends');
      } else if (depth == 0 && (c == ';' || c == ',')) {
        fail('kDebugMode ternary at ${m.start} has no ":" before its expression ends');
      } else if (depth == 0 && c == ':') {
        end = i;
      }
      i++;
    }
    ranges.add((m.end, end ?? fail('kDebugMode ternary at ${m.start} never reaches its ":"')));
  }
  return ranges;
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
      const sample = ['getSystemStatus', 'chat_sendMessage', 'chat_setNickname', 'experiment_getStatus'];
      expect(_nativeMethods(), containsAll(sample));
      expect(_dartInvokedMethods(), containsAll(sample));
    });

    test('the experiment methods (#70) are on both sides', () {
      const experiment = ['experiment_getStatus', 'experiment_startSender', 'experiment_stopSender'];
      expect(_nativeMethods(), containsAll(experiment));
      expect(_dartInvokedMethods(), containsAll(experiment));
    });

    test('no Dart call falls through to notImplemented', () {
      final missing = _dartInvokedMethods().difference(_nativeMethods());

      expect(missing, isEmpty, reason: 'answered with notImplemented by BridgeMethodDispatcher');
    });

    test('the dead register / getProfile calls are gone', () {
      expect(_dartInvokedMethods(), isNot(anyOf(contains('register'), contains('getProfile'))));
    });

    test('the polled getNearbyPeers is gone on both sides (#53: chat_peers snapshots)', () {
      expect(_nativeMethods(), isNot(contains('getNearbyPeers')));
      expect(_dartInvokedMethods(), isNot(contains('getNearbyPeers')));
    });
  });

  group('Dart takes every chat snapshot Kotlin pushes', () {
    // Kotlin names each `chat_*` event in ChatSerialization's EVENT_* constants; ChatService only
    // keeps the types it has a `case ChatEvents.x` for and ignores the rest.
    Set<String> kotlinEvents() => {
          for (final m in RegExp(r'const val EVENT_\w+ = "(\w+)"').allMatches(_read('$_kotlinBridgeDir/ChatSerialization.kt')))
            m.group(1)!,
        };

    Map<String, String> dartEvents() {
      final block = RegExp(r'abstract final class ChatEvents \{(.*?)\n\}', dotAll: true).firstMatch(_read(_dartBridge))?.group(1) ??
          fail('ChatEvents not found in $_dartBridge');
      return {for (final m in RegExp(r"static const (\w+) = '([^']+)';").allMatches(block)) m.group(1)!: m.group(2)!};
    }

    test('the two sides name the same events', () {
      expect(kotlinEvents(), containsAll(['chat_public_messages', 'chat_conversations']));
      expect(dartEvents().values.toSet(), kotlinEvents());
    });

    test('ChatService handles each of them', () {
      final service = _read('lib/services/chat_service.dart');
      final handled = {for (final m in RegExp(r'case ChatEvents\.(\w+):').allMatches(service)) m.group(1)!};

      expect(handled, dartEvents().keys.toSet());
    });
  });

  group('Dart knows every error code the chat bridge refuses with', () {
    test('the two sides list the same codes', () {
      final kotlinCodes = _kotlinErrorCodes('$_kotlinBridgeDir/ChatBridge.kt');

      expect(kotlinCodes.values, isNotEmpty);
      expect(_dartErrorCodes('ChatErrors'), kotlinCodes.values.toSet());
    });
  });

  group('Dart knows every error code the experiment bridge refuses with (#70)', () {
    test('the two sides list the same codes', () {
      final kotlinCodes = _kotlinErrorCodes(_kotlinExperimentBridge);

      expect(kotlinCodes.values, containsAll(['INVALID_ARGUMENT', 'SERVICE_NOT_READY', 'ALREADY_RUNNING']));
      expect(_dartErrorCodes('ExperimentErrors'), kotlinCodes.values.toSet());
    });
  });

  group('the experiment screen cannot be reached in a release build (#70)', () {
    // The only entry is the home header's shield, built only when `kDebugMode`. Being a
    // compile-time constant, `kDebugMode` drops the entry from release builds, and with it the last
    // reference to ExperimentScreen, so the screen is tree-shaken away too.
    final mentionsScreen = RegExp(r'\bExperimentScreen\b');

    test('only the home screen refers to it', () {
      final files = {
        for (final entry in _libSources().entries)
          if (mentionsScreen.hasMatch(_withoutCommentLines(entry.value))) entry.key,
      };

      expect(files, {'lib/screens/experiment_screen.dart', 'lib/screens/home_screen.dart'});
    });

    test('the home screen refers to it only inside a kDebugMode ? … : … branch', () {
      final home = _withoutCommentLines(_read('lib/screens/home_screen.dart'));
      final ranges = _debugOnlyRanges(home);
      final uses = mentionsScreen.allMatches(home).map((m) => m.start).toList();

      expect(uses, isNotEmpty);
      for (final use in uses) {
        final line = '\n'.allMatches(home.substring(0, use)).length + 1;
        expect(ranges.any((r) => r.$1 <= use && use < r.$2), isTrue,
            reason: 'home_screen.dart:$line uses ExperimentScreen outside a kDebugMode branch');
      }
    });

    test('that kDebugMode is the compile-time constant from Flutter', () {
      final home = _withoutCommentLines(_read('lib/screens/home_screen.dart'));

      expect(home, contains("import 'package:flutter/foundation.dart' show kDebugMode;"));
      expect(RegExp(r'\bkDebugMode\s*=').hasMatch(home), isFalse, reason: 'kDebugMode is shadowed');
    });

    test('nothing but the experiment screen calls the experiment bridge', () {
      final callsExperimentBridge = RegExp(r'\b(getExperimentStatus|startExperimentSender|stopExperimentSender)\b');
      final files = {
        for (final entry in _libSources().entries)
          if (callsExperimentBridge.hasMatch(_withoutCommentLines(entry.value))) entry.key,
      };

      expect(files, {_dartBridge, 'lib/screens/experiment_screen.dart'});
    });

    test('the scanner sees what a kDebugMode branch covers', () {
      const source = '''
        final a = kDebugMode ? GestureDetector(onLongPress: () => go(const X()), child: s) : s;
        final b = X();
      ''';
      final ranges = _debugOnlyRanges(source);
      bool covered(String needle, [int from = 0]) {
        final at = source.indexOf(needle, from);
        return ranges.any((r) => r.$1 <= at && at < r.$2);
      }

      expect(ranges, hasLength(1));
      expect(covered('X()'), isTrue);
      expect(covered('s;'), isFalse, reason: 'the release branch');
      expect(covered('X()', source.indexOf('final b')), isFalse);
    });

    test('a name in a comment line is not code, one after code still is', () {
      const source = '  /// opens [ExperimentScreen]\n  go(); // ExperimentScreen\n';
      final stripped = _withoutCommentLines(source);

      expect(stripped.length, source.length);
      expect(mentionsScreen.allMatches(stripped).map((m) => m.start), [source.lastIndexOf('ExperimentScreen')]);
    });
  });

  group('Dart explains every error the native sendHealthReport answers with', () {
    test('the two sides list the same codes', () {
      final channels = _read('$_kotlinBridgeDir/BitchatFlutterChannels.kt');
      final start = channels.indexOf('"sendHealthReport" ->');
      expect(start, isNot(-1), reason: 'sendHealthReport branch not found');
      final branch = channels.substring(start, channels.indexOf('else -> return false', start));
      final kotlinCodes = {for (final m in RegExp(r'result\.error\("(\w+)"').allMatches(branch)) m.group(1)!};

      final block = RegExp(r'abstract final class HealthReportErrors \{([^}]*)\}').firstMatch(_read(_dartBridge))?.group(1) ??
          fail('HealthReportErrors not found in $_dartBridge');
      final dartCodes = {for (final m in RegExp(r"static const \w+ = '([^']+)';").allMatches(block)) m.group(1)!};

      expect(kotlinCodes, isNotEmpty);
      expect(dartCodes, kotlinCodes);
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
