import 'package:buzz/shared/read_state/read_state_format.dart';
import 'package:buzz/shared/read_state/read_state_gc.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = 'channel-1';
final _msgKey = msgContextKey('a' * 64);
final _threadKey = threadContextKey('b' * 64);

void main() {
  group('dropDominatedContexts', () {
    test('drops a msg entry covered by its channel marker', () {
      final contexts = {_channel: 100, _msgKey: 90};
      final dropped = dropDominatedContexts(contexts, {
        _msgKey: const ContextParent(c: _channel, r: null),
      });
      expect(dropped, 1);
      expect(contexts.containsKey(_msgKey), isFalse);
      expect(contexts[_channel], 100, reason: 'channel keys never drop');
    });

    test('drops a msg entry covered by its thread frontier alone', () {
      final contexts = {_channel: 50, _threadKey: 120, _msgKey: 100};
      final dropped = dropDominatedContexts(contexts, {
        _msgKey: ContextParent(c: _channel, r: 'b' * 64),
      });
      expect(dropped, 1);
      expect(contexts.containsKey(_msgKey), isFalse);
    });

    test('keeps a msg entry above both parent frontiers', () {
      final contexts = {_channel: 100, _threadKey: 120, _msgKey: 150};
      final dropped = dropDominatedContexts(contexts, {
        _msgKey: ContextParent(c: _channel, r: 'b' * 64),
      });
      expect(dropped, 0);
      expect(contexts[_msgKey], 150);
    });

    test('never drops an unmapped entry', () {
      final contexts = {_channel: 100, _msgKey: 90};
      expect(dropDominatedContexts(contexts, {}), 0);
      expect(contexts[_msgKey], 90);
    });

    test('judges only against the outgoing map, never wider state', () {
      // The parent channel key is absent from the outgoing map — dropping on
      // the strength of state other devices never saw would resurrect the
      // event as unread on them.
      final contexts = {_msgKey: 90};
      expect(
        dropDominatedContexts(contexts, {
          _msgKey: const ContextParent(c: _channel, r: null),
        }),
        0,
      );
      expect(contexts[_msgKey], 90);
    });

    test('thread tie is dominated; transitive msg coverage stays sound', () {
      final contexts = {_channel: 100, _threadKey: 100, _msgKey: 95};
      final dropped = dropDominatedContexts(contexts, {
        _msgKey: ContextParent(c: _channel, r: 'b' * 64),
        _threadKey: const ContextParent(c: _channel, r: null),
      });
      expect(dropped, 2);
      expect(contexts, {_channel: 100});
    });
  });

  group('trimContextsToBudget', () {
    test('leaves an under-budget map untouched', () {
      final contexts = {_channel: 100, _msgKey: 90};
      final result = trimContextsToBudget(contexts, 'client', 32768, {});
      expect(result.evicted, 0);
      expect(result.fitsAfterTrim, isTrue);
      expect(contexts.length, 2);
    });

    test('evicts by read-action recency, not marker value', () {
      // The OLD-VALUED marker was affirmed recently; the NEW-VALUED one has
      // the oldest read action and must be evicted first.
      final oldValueRecentAction = msgContextKey('c' * 64);
      final newValueStaleAction = msgContextKey('d' * 64);
      final contexts = {
        _channel: 100,
        oldValueRecentAction: 10,
        newValueStaleAction: 90,
      };
      // Budget forces exactly one eviction.
      final budget =
          _blobLength({..._onlyChannel(contexts), oldValueRecentAction: 10}) +
          4;
      final result = trimContextsToBudget(contexts, 'client', budget, {
        oldValueRecentAction: 5_000,
        newValueStaleAction: 1_000,
      });
      expect(result.evicted, greaterThan(0));
      expect(
        contexts.containsKey(oldValueRecentAction),
        isTrue,
        reason: 'recently re-affirmed marker survives despite its old value',
      );
      expect(contexts.containsKey(newValueStaleAction), isFalse);
    });

    test('never evicts channel keys — reports unfittable instead', () {
      final contexts = {
        for (var index = 0; index < 40; index++)
          'channel-$index-${'x' * 48}': index + 1,
      };
      final result = trimContextsToBudget(contexts, 'client', 64, {});
      expect(result.fitsAfterTrim, isFalse);
      expect(contexts.length, 40);
    });
  });
}

Map<String, int> _onlyChannel(Map<String, int> contexts) => {
  _channel: contexts[_channel]!,
};

int _blobLength(Map<String, int> contexts) {
  final entries = contexts.entries
      .map((entry) => '"${entry.key}":${entry.value}')
      .join(',');
  return '{"v":1,"client_id":"client","contexts":{$entries}}'.length;
}
