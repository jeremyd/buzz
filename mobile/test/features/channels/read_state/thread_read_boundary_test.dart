import 'package:buzz/shared/read_state/thread_read_boundary.dart';
import 'package:flutter_test/flutter_test.dart';

const _self =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _other =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

ThreadBoundaryReply _reply(
  String id,
  int createdAt, {
  String pubkey = _other,
}) => (id: id, createdAt: createdAt, pubkey: pubkey);

void main() {
  group('computeThreadReadBoundary', () {
    test('returns null for an empty reply set — never mint a thread key', () {
      expect(
        computeThreadReadBoundary(replies: const [], getReadAt: (_) => null),
        isNull,
      );
    });

    test('advances to max reply createdAt when every reply is read', () {
      final readAt = {'r1': 100, 'r2': 200};
      expect(
        computeThreadReadBoundary(
          replies: [_reply('r1', 100), _reply('r2', 200)],
          getReadAt: (id) => readAt[id],
        ),
        200,
      );
    });

    test('ties count as read (createdAt == readAt)', () {
      expect(
        computeThreadReadBoundary(
          replies: [_reply('r1', 100)],
          getReadAt: (_) => 100,
        ),
        100,
      );
    });

    test('stops below the oldest unread reply', () {
      final readAt = {'r1': 100, 'r3': 300};
      expect(
        computeThreadReadBoundary(
          replies: [_reply('r1', 100), _reply('r2', 200), _reply('r3', 300)],
          getReadAt: (id) => readAt[id],
        ),
        199,
        reason: 'r2 is unread — boundary is min(unread) - 1, not max',
      );
    });

    test('self-authored replies count as read without a marker', () {
      expect(
        computeThreadReadBoundary(
          replies: [_reply('mine', 500, pubkey: _self.toUpperCase())],
          getReadAt: (_) => null,
          currentPubkey: _self,
        ),
        500,
        reason: 'pubkey comparison is case-insensitive',
      );
    });

    test('forced-unread caps the boundary below the forced reply', () {
      expect(
        computeThreadReadBoundary(
          replies: [_reply('r1', 100), _reply('r2', 200)],
          getReadAt: (_) => 999,
          isForcedUnread: (id) => id == 'r2',
        ),
        199,
      );
    });

    test('returns null when the boundary is not a positive timestamp', () {
      expect(
        computeThreadReadBoundary(
          replies: [_reply('r1', 1)],
          getReadAt: (_) => null,
        ),
        isNull,
        reason: 'min(unread) - 1 == 0 is not a valid frontier',
      );
    });
  });
}
