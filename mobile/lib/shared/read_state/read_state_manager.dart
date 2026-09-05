import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/nip44.dart';
import '../relay/relay.dart';
import 'read_state_format.dart';
import 'read_state_gc.dart';
import 'read_state_storage.dart';
import 'read_state_time.dart';

class ReadStateCrypto {
  final Uint8List conversationKey;

  const ReadStateCrypto._(this.conversationKey);

  static ReadStateCrypto? tryCreate({
    required String nsec,
    required String pubkey,
  }) {
    try {
      final privkeyHex = nostr.Nip19.decode(payload: nsec).data;
      if (privkeyHex.isEmpty || pubkey.isEmpty) {
        return null;
      }
      return ReadStateCrypto._(getConversationKey(privkeyHex, pubkey));
    } catch (e) {
      debugPrint('[ReadStateManager] crypto init failed: $e');
      return null;
    }
  }

  String encrypt(String plaintext) => nip44Encrypt(conversationKey, plaintext);

  String decrypt(String ciphertext) =>
      nip44Decrypt(conversationKey, ciphertext);
}

enum _ApplyRemoteContextResult { unchanged, advanced }

class ReadStateManager {
  final String pubkey;
  final ReadStateCrypto _crypto;
  final ReadStateStorage _storage;
  final RelaySessionNotifier? _relaySession;
  final SignedEventRelay? _signedEventRelay;
  final bool _remoteEnabled;
  final VoidCallback _onChanged;

  late final String _clientId;
  late String _slotId;

  final Map<String, int> _effectiveState = {};
  final Set<String> _publishableContextIds = {};
  Map<String, int> _lastPublishedContexts = {};

  Timer? _debounceTimer;
  void Function()? _unsubscribeLive;
  bool _initialized = false;
  bool _disposed = false;
  bool _isPublishing = false;
  Completer<void>? _publishCompleter;
  bool _remoteUnsupported = false;
  int _maxFetchedCreatedAt = 0;
  final Map<String, int> _contextSourceCreatedAt = {};
  final Map<String, ContextParent> _contextParents = {};
  final Set<String> _pendingSyncedAdvances = {};

  ReadStateManager({
    required this.pubkey,
    required SharedPreferences prefs,
    required ReadStateCrypto crypto,
    required RelaySessionNotifier? relaySession,
    required SignedEventRelay? signedEventRelay,
    required bool remoteEnabled,
    required VoidCallback onChanged,
  }) : _crypto = crypto,
       _storage = ReadStateStorage(prefs),
       _relaySession = relaySession,
       _signedEventRelay = signedEventRelay,
       _remoteEnabled = remoteEnabled,
       _onChanged = onChanged {
    _clientId = _storage.getOrCreateClientId(pubkey);
    _slotId = _storage.getOrCreateSlotId(pubkey);
    _hydrateFromLocalStorage();
  }

  Map<String, int> get effectiveContexts => Map.unmodifiable(_effectiveState);

  int? getEffectiveTimestamp(String contextId) => _effectiveState[contextId];

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    debugPrint(
      '[ReadStateManager] initialize pubkey=${pubkey.substring(0, 8)}… clientId=${_clientId.substring(0, 8)}… slotId=$_slotId',
    );

    if (!_remoteEnabled || _relaySession == null) {
      _onChanged();
      return;
    }

    await _fetchAndMerge();
    await _startLiveSubscription();
    if (_hasUnpublishedChanges()) {
      _schedulePublish();
    }

    _onChanged();
    debugPrint(
      '[ReadStateManager] initialize complete maxFetchedCreatedAt=$_maxFetchedCreatedAt contexts=${_effectiveState.length}',
    );
  }

  void markContextRead(
    String contextId,
    int unixTimestamp, {
    ContextParent? parent,
  }) {
    if (parent != null) {
      recordContextParent(contextId, parent);
    }
    _advanceContext(contextId, unixTimestamp, publishable: true);
    _contextSourceCreatedAt[contextId] = max(
      currentUnixSeconds(),
      _maxFetchedCreatedAt + 1,
    );
  }

  /// Record the parent coordinates of a `msg:`/`thread:` context, captured at
  /// mark time where the event graph is available. Powers the
  /// dominated-marker GC on the publish path; contexts with no recorded
  /// parent are never GC'd. Idempotent.
  void recordContextParent(String contextId, ContextParent parent) {
    if (_disposed) return;
    if (_contextParents[contextId] == parent) return;
    _contextParents[contextId] = parent;
    _persistLocalState();
  }

  void seedContextRead(String contextId, int unixTimestamp) {
    _advanceContext(contextId, unixTimestamp, publishable: false);
  }

  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!_remoteEnabled || _remoteUnsupported || _disposed) return;
    await _publish();
  }

  Future<void> reinitializeRemote() async {
    if (_disposed || !_remoteEnabled || !_initialized) return;
    debugPrint('[ReadStateManager] reinitializeRemote');
    if (_isPublishing) {
      await _publishCompleter?.future;
    }
    _unsubscribeLive?.call();
    _unsubscribeLive = null;
    await _fetchAndMerge();
    await _startLiveSubscription();
    if (_hasUnpublishedChanges()) {
      _schedulePublish();
    }
    _onChanged();
  }

  void dispose({bool flushPending = true}) {
    if (_disposed) return;
    _disposed = true;

    final hadPendingPublish = _debounceTimer != null;
    _debounceTimer?.cancel();
    _debounceTimer = null;

    if (flushPending &&
        hadPendingPublish &&
        _remoteEnabled &&
        !_remoteUnsupported) {
      unawaited(_publish(allowDisposed: true));
    }

    _unsubscribeLive?.call();
    _unsubscribeLive = null;
  }

  void _advanceContext(
    String contextId,
    int unixTimestamp, {
    required bool publishable,
  }) {
    if (_disposed || unixTimestamp < 0) return;

    final current = _effectiveState[contextId] ?? 0;
    if (unixTimestamp <= current) {
      if (!publishable || _publishableContextIds.contains(contextId)) {
        return;
      }

      _publishableContextIds.add(contextId);
      _persistLocalState();
      _onChanged();
      _schedulePublish();
      return;
    }

    _effectiveState[contextId] = unixTimestamp;
    if (publishable) {
      _publishableContextIds.add(contextId);
    }
    _persistLocalState();
    _onChanged();
    if (publishable) {
      _schedulePublish();
    }
  }

  Future<void> _fetchAndMerge() async {
    try {
      final events = await _relaySession!.fetchHistory(
        NostrFilter(
          kinds: const [EventKind.readState],
          authors: [pubkey],
          tags: const {
            '#t': ['read-state'],
          },
          since: currentUnixSeconds() - readStateHorizonSeconds,
          limit: readStateFetchLimit,
        ),
      );
      _mergeEvents(events);
      _persistLocalState();
      _onChanged();
    } catch (e) {
      debugPrint('[ReadStateManager] fetchAndMerge failed: $e');
    }
  }

  void _mergeEvents(List<NostrEvent> events) {
    ReadStateBlob? ownBlob;
    var ownBlobCreatedAt = 0;

    for (final event in events) {
      final decoded = decodeReadStateEvent(
        event,
        pubkey: pubkey,
        decrypt: _crypto.decrypt,
      );
      if (decoded == null) continue;

      if (_isPlausibleCreatedAt(event.createdAt)) {
        _maxFetchedCreatedAt = max(_maxFetchedCreatedAt, event.createdAt);
      }

      if (decoded.dTag == '$readStateDTagPrefix$_slotId' &&
          decoded.blob.clientId != _clientId) {
        _rotateSlotId();
      }

      for (final entry in decoded.blob.contexts.entries) {
        final result = _applyRemoteContextTimestamp(
          contextId: entry.key,
          timestamp: entry.value,
          eventCreatedAt: event.createdAt,
        );
        if (result == _ApplyRemoteContextResult.advanced) {
          _pendingSyncedAdvances.add(entry.key);
          _publishableContextIds.add(entry.key);
        }
      }

      if (decoded.blob.clientId == _clientId &&
          event.createdAt > ownBlobCreatedAt) {
        ownBlob = decoded.blob;
        ownBlobCreatedAt = event.createdAt;
      }
    }

    if (ownBlob != null) {
      _lastPublishedContexts = Map<String, int>.from(ownBlob.contexts);
      _publishableContextIds.addAll(ownBlob.contexts.keys);
    }
  }

  Future<void> _startLiveSubscription() async {
    try {
      final unsub = await _relaySession!.subscribe(
        NostrFilter(
          kinds: const [EventKind.readState],
          authors: [pubkey],
          tags: const {
            '#t': ['read-state'],
          },
          limit: readStateFetchLimit,
        ),
        _handleIncomingEvent,
      );
      if (_disposed) {
        unsub.call();
        return;
      }
      _unsubscribeLive = unsub;
      debugPrint('[ReadStateManager] live subscription established');
    } catch (e) {
      debugPrint('[ReadStateManager] live subscription FAILED: $e');
    }
  }

  void _handleIncomingEvent(NostrEvent event) {
    if (_disposed) return;
    debugPrint(
      '[ReadStateManager] incoming event=${event.id.substring(0, 8)}… created_at=${event.createdAt}',
    );

    final decoded = decodeReadStateEvent(
      event,
      pubkey: pubkey,
      decrypt: _crypto.decrypt,
    );
    if (decoded == null) return;

    if (_isPlausibleCreatedAt(event.createdAt)) {
      _maxFetchedCreatedAt = max(_maxFetchedCreatedAt, event.createdAt);
    }

    if (decoded.dTag == '$readStateDTagPrefix$_slotId' &&
        decoded.blob.clientId != _clientId) {
      _rotateSlotId();
    }

    var changed = false;
    for (final entry in decoded.blob.contexts.entries) {
      final result = _applyRemoteContextTimestamp(
        contextId: entry.key,
        timestamp: entry.value,
        eventCreatedAt: event.createdAt,
      );
      if (result == _ApplyRemoteContextResult.advanced) {
        _pendingSyncedAdvances.add(entry.key);
        changed = true;
      }
      if (_publishableContextIds.add(entry.key)) {
        changed = true;
      }
    }
    debugPrint(
      '[ReadStateManager] incoming result changed=$changed clientId=${decoded.blob.clientId.substring(0, min(8, decoded.blob.clientId.length))}…',
    );

    if (decoded.blob.clientId == _clientId) {
      _lastPublishedContexts = Map<String, int>.from(decoded.blob.contexts);
    }

    if (changed) {
      _persistLocalState();
      _onChanged();
    }

    if (decoded.blob.clientId != _clientId && _hasUnpublishedChanges()) {
      _schedulePublish();
    }
  }

  /// True when the publishable snapshot differs from the last published blob.
  /// An unfittable snapshot (null) schedules nothing — publish would skip it.
  bool _hasUnpublishedChanges() {
    final contexts = _currentContexts();
    return contexts != null && !_isIdenticalToLastPublished(contexts);
  }

  _ApplyRemoteContextResult _applyRemoteContextTimestamp({
    required String contextId,
    required int timestamp,
    required int eventCreatedAt,
  }) {
    final sourceCreatedAt = _contextSourceCreatedAt[contextId] ?? 0;
    final current = _effectiveState[contextId] ?? 0;
    final next = max(current, timestamp);
    final result = next == current
        ? _ApplyRemoteContextResult.unchanged
        : _ApplyRemoteContextResult.advanced;

    if (result == _ApplyRemoteContextResult.advanced) {
      _effectiveState[contextId] = next;
    }
    if (eventCreatedAt > sourceCreatedAt) {
      _contextSourceCreatedAt[contextId] = eventCreatedAt;
    }
    return result;
  }

  void _schedulePublish() {
    if (!_remoteEnabled || _remoteUnsupported || _disposed) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 5), () {
      _debounceTimer = null;
      unawaited(_publish());
    });
  }

  Future<void> _publish({bool allowDisposed = false}) async {
    if ((!allowDisposed && _disposed) ||
        !_remoteEnabled ||
        _remoteUnsupported ||
        _signedEventRelay == null) {
      return;
    }
    if (_isPublishing) return;

    final completer = Completer<void>();
    _publishCompleter = completer;
    _isPublishing = true;
    debugPrint('[ReadStateManager] publish starting slotId=$_slotId');
    try {
      await _fetchOwnBlobBeforePublish();

      final contexts = _currentContexts();
      if (contexts == null) {
        return;
      }
      if (_isIdenticalToLastPublished(contexts)) {
        return;
      }

      final blob = ReadStateBlob(clientId: _clientId, contexts: contexts);
      final ciphertext = _crypto.encrypt(jsonEncode(blob.toJson()));
      final createdAt = max(currentUnixSeconds(), _maxFetchedCreatedAt + 1);

      await _signedEventRelay.submit(
        kind: EventKind.readState,
        content: ciphertext,
        tags: [
          ['d', '$readStateDTagPrefix$_slotId'],
          ['t', 'read-state'],
        ],
        createdAt: createdAt,
      );
      debugPrint('[ReadStateManager] publish accepted createdAt=$createdAt');

      for (final key in contexts.keys) {
        if (_lastPublishedContexts[key] != contexts[key]) {
          _contextSourceCreatedAt[key] = createdAt;
        }
      }
      _lastPublishedContexts = contexts;
      _maxFetchedCreatedAt = max(_maxFetchedCreatedAt, createdAt);
      _persistLocalState();
    } catch (error) {
      if (_isOversizedReadStateError(error)) {
        // With the publish-path GC + byte-budget trim this should be
        // unreachable; if it fires anyway, skip THIS cycle and retry on the
        // next debounce — silently disabling remote sync forever turned a
        // transient condition into a permanent, invisible cross-device
        // divergence.
        debugPrint(
          '[ReadStateManager] publish skipped: blob exceeded the NIP-44 '
          'plaintext limit after trim (will retry on the next change)',
        );
        return;
      }
      if (_isPermanentReadStateRemoteError(error)) {
        _remoteUnsupported = true;
        _debounceTimer?.cancel();
        _debounceTimer = null;
        debugPrint(
          '[ReadStateManager] remote read-state sync is unavailable; '
          'using local read state.',
        );
        return;
      }
      debugPrint('[ReadStateManager] publish failed: $error');
    } finally {
      _isPublishing = false;
      completer.complete();
      if (_publishCompleter == completer) {
        _publishCompleter = null;
      }
    }
  }

  Future<void> _fetchOwnBlobBeforePublish() async {
    if (_relaySession == null) return;

    try {
      final events = await _relaySession.fetchHistory(
        NostrFilter(
          kinds: const [EventKind.readState],
          authors: [pubkey],
          tags: {
            '#d': ['$readStateDTagPrefix$_slotId'],
          },
          limit: readStateFetchLimit,
        ),
      );
      _mergeEvents(events);
      _persistLocalState();
      if (!_disposed) {
        _onChanged();
      }
    } catch (e) {
      debugPrint('[ReadStateManager] fetchOwnBlobBeforePublish failed: $e');
    }
  }

  bool _isIdenticalToLastPublished(Map<String, int> contexts) {
    if (_lastPublishedContexts.length != contexts.length) {
      return false;
    }
    for (final entry in contexts.entries) {
      if (_lastPublishedContexts[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  Set<String> drainSyncedAdvances() {
    final drained = Set<String>.from(_pendingSyncedAdvances);
    _pendingSyncedAdvances.clear();
    return drained;
  }

  /// Publish-ready contexts, or null when even the trimmed blob cannot fit
  /// the byte budget (channel keys alone exceed it) — the caller skips that
  /// publish cycle; it is NOT a terminal state.
  Map<String, int>? _currentContexts() {
    final contexts = <String, int>{};
    for (final entry in _effectiveState.entries) {
      if (_publishableContextIds.contains(entry.key)) {
        contexts[entry.key] = entry.value;
      }
    }

    // GC before trim: every byte a dominated entry occupies is a byte that
    // can push a LOAD-BEARING marker out of the published blob, and the trim
    // below can evict load-bearing markers.
    final dropped = dropDominatedContexts(contexts, _contextParents);
    if (dropped > 0) {
      debugPrint(
        '[ReadStateManager] publish dropped $dropped dominated entries',
      );
    }
    final trim = trimContextsToBudget(
      contexts,
      _clientId,
      readStateMaxPlaintextBytes,
      _contextSourceCreatedAt,
    );
    if (trim.evicted > 0) {
      debugPrint(
        '[ReadStateManager] publish trimmed ${trim.evicted} entries to fit '
        'the byte budget',
      );
    }
    if (!trim.fitsAfterTrim) {
      debugPrint(
        '[ReadStateManager] channel keys alone exceed the publish budget — '
        'skipping this publish cycle',
      );
      return null;
    }
    return contexts;
  }

  void _hydrateFromLocalStorage() {
    final stored = _storage.read(pubkey);
    _effectiveState
      ..clear()
      ..addAll(stored.contexts);
    _publishableContextIds
      ..clear()
      ..addAll(stored.publishableContextIds);
    _contextSourceCreatedAt
      ..clear()
      ..addAll(stored.sourceCreatedAt);
    _contextParents
      ..clear()
      ..addAll(stored.contextParents);
    _persistLocalState();
  }

  void _persistLocalState() {
    _storage.write(
      pubkey,
      _effectiveState,
      _publishableContextIds,
      _contextSourceCreatedAt,
      _contextParents,
    );
  }

  void _rotateSlotId() {
    _slotId = generateReadStateSlotId();
    _storage.writeSlotId(pubkey, _slotId);
  }

  bool _isPlausibleCreatedAt(int createdAt) =>
      createdAt <= currentUnixSeconds() + readStateMaxClockDriftSeconds;

  bool _isOversizedReadStateError(Object error) {
    final msg = error.toString().toLowerCase();
    return error is ArgumentError &&
        msg.contains('plaintext must be 1-65535 bytes');
  }

  bool _isPermanentReadStateRemoteError(Object error) {
    // Relay rejections come back as `Exception("<message>")` from the
    // websocket OK handler. Pattern-match on the message text since we no
    // longer have HTTP status codes.
    final msg = error.toString().toLowerCase();
    return msg.contains('unknown event kind') ||
        msg.contains('missing users:write') ||
        msg.contains('insufficient scope') ||
        msg.contains('restricted: unknown');
  }
}
