import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/features/projects/project_models.dart';
import 'package:buzz/shared/relay/relay.dart';

NostrEvent _event({
  required int kind,
  required String pubkey,
  required int createdAt,
  required List<List<String>> tags,
  String content = '',
  String id = 'e',
}) => NostrEvent(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: kind,
  tags: tags,
  content: content,
  sig: 's',
);

void main() {
  final owner = 'a' * 64;
  final other = 'b' * 64;

  group('buildProjectReadModels', () {
    test('parses explicit project with attached repository', () {
      final repo = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 100,
        tags: <List<String>>[
          ['d', 'my-repo'],
          ['name', 'My Repo'],
          ['clone', 'https://example.com/repo.git'],
        ],
        content: 'A repo description',
      );
      final project = _event(
        kind: 30621,
        pubkey: owner,
        createdAt: 200,
        tags: <List<String>>[
          ['d', 'my-repo'],
          ['name', 'My Project'],
          ['a', '30617:$owner:my-repo'],
        ],
      );
      final projects = buildProjectReadModels(
        projectEvents: [project],
        repositoryEvents: [repo],
      );
      expect(projects, hasLength(1));
      expect(projects.first.name, 'My Project');
      expect(projects.first.repositories, hasLength(1));
      expect(projects.first.repositories.first.name, 'My Repo');
      expect(projects.first.repositories.first.cloneUrls, [
        'https://example.com/repo.git',
      ]);
      expect(projects.first.unavailableRepositoryAddresses, isEmpty);
      expect(projects.first.legacy, isFalse);
    });

    test('unattached repository becomes a legacy project', () {
      final repo = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 100,
        tags: <List<String>>[
          ['d', 'lone-repo'],
        ],
      );
      final projects = buildProjectReadModels(
        projectEvents: [],
        repositoryEvents: [repo],
      );
      expect(projects, hasLength(1));
      expect(projects.first.legacy, isTrue);
      expect(projects.first.name, 'lone-repo');
    });

    test('deleted announcements are dropped (NIP-09 tombstones)', () {
      final repo = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 100,
        tags: <List<String>>[
          ['d', 'gone'],
        ],
      );
      final tombstone = _event(
        kind: 5,
        pubkey: owner,
        createdAt: 300,
        tags: [
          ['a', '30617:$owner:gone'],
        ],
      );
      final projects = buildProjectReadModels(
        projectEvents: [],
        repositoryEvents: [repo],
        deletionEvents: [tombstone],
      );
      expect(projects, isEmpty);
    });

    test('tombstone older than the event does not delete it', () {
      final repo = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 400,
        tags: <List<String>>[
          ['d', 'alive'],
        ],
      );
      final tombstone = _event(
        kind: 5,
        pubkey: owner,
        createdAt: 300,
        tags: [
          ['a', '30617:$owner:alive'],
        ],
      );
      final projects = buildProjectReadModels(
        projectEvents: [],
        repositoryEvents: [repo],
        deletionEvents: [tombstone],
      );
      expect(projects, hasLength(1));
    });

    test('unlisted projects are filtered out', () {
      final project = _event(
        kind: 30621,
        pubkey: owner,
        createdAt: 100,
        tags: <List<String>>[
          ['d', 'secret'],
          ['buzz-visibility', 'unlisted'],
        ],
      );
      final projects = buildProjectReadModels(
        projectEvents: [project],
        repositoryEvents: [],
      );
      expect(projects, isEmpty);
    });

    test('invalid d-tag length is rejected', () {
      final repo = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 100,
        tags: [
          ['d', 'x' * 2000],
        ],
      );
      final projects = buildProjectReadModels(
        projectEvents: [],
        repositoryEvents: [repo],
      );
      expect(projects, isEmpty);
    });

    test('newer announcement head wins dedup', () {
      final oldHead = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 100,
        tags: <List<String>>[
          ['d', 'r'],
          ['name', 'Old'],
        ],
        id: 'a',
      );
      final newHead = _event(
        kind: 30617,
        pubkey: owner,
        createdAt: 200,
        tags: <List<String>>[
          ['d', 'r'],
          ['name', 'New'],
        ],
        id: 'b',
      );
      final projects = buildProjectReadModels(
        projectEvents: [],
        repositoryEvents: [oldHead, newHead],
      );
      expect(projects, hasLength(1));
      expect(projects.first.name, 'New');
    });

    test('projects sort newest first', () {
      final combined = buildProjectReadModels(
        projectEvents: [],
        repositoryEvents: [
          _event(
            kind: 30617,
            pubkey: owner,
            createdAt: 100,
            tags: <List<String>>[
              ['d', 'a'],
            ],
          ),
          _event(
            kind: 30617,
            pubkey: other,
            createdAt: 200,
            tags: <List<String>>[
              ['d', 'b'],
            ],
          ),
        ],
      );
      expect(combined, hasLength(2));
      expect(combined.first.createdAt, greaterThan(combined.last.createdAt));
    });
  });
}
