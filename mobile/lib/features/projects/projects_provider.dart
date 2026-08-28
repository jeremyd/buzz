/// Riverpod provider for the projects list (NIP-34 read path).
///
/// Mirrors desktop `fetchProjects`: enumerate kind:30621 project
/// announcements and kind:30617 repo announcements, then fetch scoped
/// kind:5 tombstones for their coordinates (fail-closed: a tombstone fetch
/// error surfaces rather than resurrecting deleted heads).
library;

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';
import 'project_models.dart';
import 'project_issues.dart';

/// Query the relay HTTP bridge with a websocket fallback for one filter.
Future<List<NostrEvent>> relayFetch(
  RelaySessionNotifier session,
  NostrFilter filter,
) async {
  try {
    return await session.queryRelay([filter]);
  } catch (_) {
    return await session.fetchHistory(filter);
  }
}

/// Loads issues (and their aggregate context events) for one repository,
/// mirroring desktop `fetchProjectsWorkItems` scoped to a single repo.
Future<RepoIssuesResult> fetchRepoIssues(
  RelayFetch fetch,
  String repoAddress,
) async {
  final rootEvents = await fetch(
    NostrFilter(
      kinds: [kindGitIssue],
      tags: {
        '#a': [repoAddress],
      },
      limit: 2000,
    ),
  );
  final results = await Future.wait([
    fetch(
      NostrFilter(
        kinds: [1],
        tags: {
          '#a': [repoAddress],
        },
        limit: 2000,
      ),
    ),
    fetch(
      NostrFilter(
        kinds: [
          kindGitStatusOpen,
          kindGitStatusMerged,
          kindGitStatusClosed,
          kindGitStatusDraft,
        ],
        tags: {
          '#a': [repoAddress],
        },
        limit: 2000,
      ),
    ),
    fetchAssignmentOperationEvents(fetch, [
      for (final event in rootEvents) event.id,
    ]),
  ]);
  final commentEvents = mergeEventsById(results[0], results[2]);
  final statusEvents = results[1];

  return RepoIssuesResult(
    issues: projectIssueEventsToIssues(
      issueEvents: rootEvents,
      statusEvents: statusEvents,
      commentEvents: commentEvents,
    ),
    rootEvents: rootEvents,
    commentEvents: commentEvents,
    statusEvents: statusEvents,
  );
}

const _kindDeletion = 5;
const _kindRepoAnnouncement = 30617;
const _kindProjectAnnouncement = 30621;

class ProjectsNotifier extends AsyncNotifier<List<Project>> {
  @override
  Future<List<Project>> build() async {
    final session = ref.read(relaySessionProvider.notifier);
    final connected =
        ref.watch(relaySessionProvider).status == SessionStatus.connected;
    // Wait for the first connection before querying (the HTTP bridge needs
    // a configured session; queries retry on refresh otherwise).
    if (!connected) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    Future<List<NostrEvent>> fetch(List<NostrFilter> filters) async {
      try {
        return await session.queryRelay(filters);
      } catch (_) {
        return [
          for (final filter in filters) ...await session.fetchHistory(filter),
        ];
      }
    }

    final results = await Future.wait([
      fetch([
        NostrFilter(kinds: [_kindProjectAnnouncement], limit: 500),
      ]),
      fetch([
        NostrFilter(kinds: [_kindRepoAnnouncement], limit: 500),
      ]),
    ]);
    final projectEvents = results[0];
    final repositoryEvents = results[1];

    // Tombstones scoped to announcement coordinates (chunked like desktop).
    final coordinates = [
      for (final event in [...projectEvents, ...repositoryEvents])
        if (event.getTagValue('d') != null)
          '${event.kind}:${event.pubkey.toLowerCase()}:${event.getTagValue('d')}',
    ];
    var tombstoneEvents = <NostrEvent>[];
    if (coordinates.isNotEmpty) {
      for (var i = 0; i < coordinates.length; i += 100) {
        final chunk = coordinates.sublist(
          i,
          (i + 100 > coordinates.length) ? coordinates.length : i + 100,
        );
        // Fail-closed: let tombstone errors propagate (deleted heads must
        // not resurrect silently).
        tombstoneEvents = [
          ...tombstoneEvents,
          ...await fetch([
            NostrFilter(
              kinds: [_kindDeletion],
              tags: {'#a': chunk},
              limit: 500,
            ),
          ]),
        ];
      }
    }

    return buildProjectReadModels(
      projectEvents: projectEvents,
      repositoryEvents: repositoryEvents,
      deletionEvents: tombstoneEvents,
    );
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final projectsProvider = AsyncNotifierProvider<ProjectsNotifier, List<Project>>(
  ProjectsNotifier.new,
);

/// Issues for a single repository (kind:1621 + statuses + comments).
/// Re-fetches on refresh via `ref.invalidate(repoIssuesProvider(repoAddress))`.
final repoIssuesProvider = FutureProvider.family<List<ProjectIssue>, String>((
  ref,
  repoAddress,
) async {
  final session = ref.read(relaySessionProvider.notifier);
  final result = await fetchRepoIssues(
    (filter) => relayFetch(session, filter),
    repoAddress,
  );
  return result.issues;
});
