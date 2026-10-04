import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/chat_peer.dart';

/// Exactly what Kotlin `ChatSerialization.peer` produces.
Map<String, Object?> _peer({
  String peerID = '1111111111111111',
  String? nickname = 'alice',
  String displayName = 'alice',
  String displaySuffix = '',
  int? rssi = -67,
  int? signalBars = 2,
  String connection = 'bluetooth',
  int unreadCount = 0,
  bool isFavorite = false,
  bool theyFavoritedUs = false,
}) =>
    {
      'peerID': peerID,
      'nickname': nickname,
      'displayName': displayName,
      'displaySuffix': displaySuffix,
      'rssi': rssi,
      'signalBars': signalBars,
      'connection': connection,
      'unreadCount': unreadCount,
      'isFavorite': isFavorite,
      'theyFavoritedUs': theyFavoritedUs,
    };

void main() {
  group('ChatPeer.fromMap', () {
    test('reads every bridge field', () {
      final peer = ChatPeer.fromMap(
        _peer(displaySuffix: '#beef', unreadCount: 4, isFavorite: true, theyFavoritedUs: true),
      )!;

      expect(peer.peerID, '1111111111111111');
      expect(peer.nickname, 'alice');
      expect(peer.displayName, 'alice');
      expect(peer.displaySuffix, '#beef');
      expect(peer.rssi, -67);
      expect(peer.signalBars, 2);
      expect(peer.connection, ChatPeerConnection.bluetooth);
      expect(peer.unreadCount, 4);
      expect(peer.isFavorite, isTrue);
      expect(peer.theyFavoritedUs, isTrue);
    });

    test('the favourite star reads both directions separately (#58)', () {
      final ours = ChatPeer.fromMap(_peer(isFavorite: true))!;
      final theirs = ChatPeer.fromMap(_peer(theyFavoritedUs: true))!;

      expect([ours.isFavorite, ours.theyFavoritedUs], [true, false]);
      expect([theirs.isFavorite, theirs.theyFavoritedUs], [false, true]);
    });

    test('missing or wrongly typed favourite flags are no favourite, never thrown on (#58)', () {
      final missing = ChatPeer.fromMap(_peer()..remove('isFavorite')..remove('theyFavoritedUs'))!;
      final wrong = ChatPeer.fromMap(_peer()..['isFavorite'] = 'yes'..['theyFavoritedUs'] = 1)!;

      for (final peer in [missing, wrong]) {
        expect(peer.isFavorite, isFalse);
        expect(peer.theyFavoritedUs, isFalse);
      }
    });

    test('an offline favourite is offline and not on the mesh (#58)', () {
      final offline = ChatPeer.fromMap(_peer(
        peerID: 'd' * 64,
        nickname: null,
        rssi: null,
        signalBars: null,
        connection: 'offline',
        isFavorite: true,
      ))!;

      expect(offline.connection, ChatPeerConnection.offline);
      expect(offline.isOnline, isFalse);
      expect(offline.peerID, 'd' * 64);
      expect(ChatPeer.fromMap(_peer(connection: 'routed'))!.isOnline, isTrue);
    });

    test('nothing unread is zero (#56)', () {
      expect(ChatPeer.fromMap(_peer())!.unreadCount, 0);
      expect(ChatPeer.fromMap(_peer()..remove('unreadCount'))!.unreadCount, 0);
    });

    test('an unread count that is not a non-negative int is zero, never thrown on (#56)', () {
      expect(ChatPeer.fromMap(_peer()..['unreadCount'] = '3')!.unreadCount, 0);
      expect(ChatPeer.fromMap(_peer()..['unreadCount'] = -1)!.unreadCount, 0);
      expect(ChatPeer.fromMap(_peer()..['unreadCount'] = null)!.unreadCount, 0);
    });

    test('reads each connection kind', () {
      expect(ChatPeer.fromMap(_peer(connection: 'bluetooth'))!.connection, ChatPeerConnection.bluetooth);
      expect(ChatPeer.fromMap(_peer(connection: 'wifiAware'))!.connection, ChatPeerConnection.wifiAware);
      expect(ChatPeer.fromMap(_peer(connection: 'routed'))!.connection, ChatPeerConnection.routed);
    });

    test('an unknown or missing connection is unknown, not a guess', () {
      expect(ChatPeer.fromMap(_peer(connection: 'lora'))!.connection, ChatPeerConnection.unknown);
      expect(ChatPeer.fromMap(_peer()..remove('connection'))!.connection, ChatPeerConnection.unknown);
    });

    test('keeps the nulls upstream sends', () {
      final peer = ChatPeer.fromMap(_peer(nickname: null, rssi: null, signalBars: null))!;

      expect(peer.nickname, isNull);
      expect(peer.rssi, isNull);
      expect(peer.signalBars, isNull);
    });

    test('signal bars outside 0 to 3 are dropped', () {
      expect(ChatPeer.fromMap(_peer(signalBars: 4))!.signalBars, isNull);
      expect(ChatPeer.fromMap(_peer(signalBars: -1))!.signalBars, isNull);
      expect(ChatPeer.fromMap(_peer(signalBars: 0))!.signalBars, 0);
    });

    test('wrongly typed fields fall back instead of throwing', () {
      final peer = ChatPeer.fromMap({
        'peerID': '1111111111111111',
        'nickname': 42,
        'displayName': 7,
        'displaySuffix': null,
        'rssi': '-60',
        'signalBars': 'two',
        'connection': 1,
      })!;

      expect(peer.nickname, isNull);
      expect(peer.displayName, '1111111111111111', reason: 'a row always has something to show');
      expect(peer.displaySuffix, '');
      expect(peer.rssi, isNull);
      expect(peer.signalBars, isNull);
      expect(peer.connection, ChatPeerConnection.unknown);
    });

    test('an entry without a peer ID is not a peer', () {
      expect(ChatPeer.fromMap(_peer()..remove('peerID')), isNull);
      expect(ChatPeer.fromMap(_peer(peerID: '')), isNull);
      expect(ChatPeer.fromMap({'peerID': 42}), isNull);
      expect(ChatPeer.fromMap('1111111111111111'), isNull);
      expect(ChatPeer.fromMap(null), isNull);
    });
  });

  group('ChatPeerList.fromEvent', () {
    Map<String, dynamic> event({Object? onlineCount = 2, Object? peers}) => {
          'type': 'chat_peers',
          'onlineCount': onlineCount,
          'peers': peers ??
              [
                _peer(peerID: '1111111111111111', displayName: 'alice'),
                _peer(peerID: '2222222222222222', displayName: 'bob'),
              ],
        };

    test('reads the online count and the peers in list order', () {
      final list = ChatPeerList.fromEvent(event())!;

      expect(list.onlineCount, 2);
      expect(list.peers.map((p) => p.displayName), ['alice', 'bob']);
    });

    test('nobody online is an empty list', () {
      final list = ChatPeerList.fromEvent(event(onlineCount: 0, peers: []))!;

      expect(list.onlineCount, 0);
      expect(list.peers, isEmpty);
    });

    test('entries that are not peers are skipped, the rest kept in order', () {
      final list = ChatPeerList.fromEvent(event(peers: [
        _peer(peerID: '1111111111111111'),
        'junk',
        {'displayName': 'no id'},
        _peer(peerID: '2222222222222222'),
      ]))!;

      expect(list.peers.map((p) => p.peerID), ['1111111111111111', '2222222222222222']);
    });

    test('reads the people section count beside the online count (#73)', () {
      // Peers with a listed conversation are shown in the conversations section instead: the
      // header's count still counts them, the people section's does not.
      final list = ChatPeerList.fromEvent(event(onlineCount: 3)..['peopleCount'] = 1)!;

      expect(list.onlineCount, 3);
      expect(list.peopleCount, 1);
    });

    test('a missing or malformed people count is unknown, not recounted (#73)', () {
      expect(ChatPeerList.fromEvent(event())!.peopleCount, isNull);
      expect(ChatPeerList.fromEvent(event()..['peopleCount'] = '1')!.peopleCount, isNull);
      expect(ChatPeerList.fromEvent(event()..['peopleCount'] = -1)!.peopleCount, isNull);
    });

    test('the count is taken as Kotlin sends it, not recounted', () {
      // Upstream's header count and its list rows are separate rules.
      final list = ChatPeerList.fromEvent(event(onlineCount: 5))!;

      expect(list.onlineCount, 5);
      expect(list.peers, hasLength(2));
    });

    test('a malformed snapshot is rejected as a whole', () {
      expect(ChatPeerList.fromEvent({'type': 'chat_peers'}), isNull);
      expect(ChatPeerList.fromEvent(event(peers: 'nope')), isNull);
      expect(ChatPeerList.fromEvent(event(onlineCount: null)), isNull);
      expect(ChatPeerList.fromEvent(event(onlineCount: '2')), isNull);
      expect(ChatPeerList.fromEvent(event(onlineCount: -1)), isNull);
    });

    test('the peers cannot be mutated by readers', () {
      final list = ChatPeerList.fromEvent(event())!;

      expect(() => list.peers.clear(), throwsUnsupportedError);
    });
  });
}
