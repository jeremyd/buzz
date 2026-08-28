/// Read models for NIP-34 issues (tasks) scoped to a repository.
///
/// Faithful port of `desktop/src/features/projects/projectIssues.mjs`
/// (projectIssueEventsToIssues / eventToProjectIssue / assignment reduction)
/// and `assignmentOperationFetch.ts` (exhaustive `#e` pagination).
/// Keep the parsing rules in sync with the desktop implementation.
library;

import '../../shared/relay/relay.dart';

const String issueAssignmentLabel = 'assignment';
const String issueUnassignmentLabel = 'unassignment';

const int kindGitIssue = 1621;
const int kindGitStatusOpen = 1630;
const int kindGitStatusMerged = 1631;
const int kindGitStatusClosed = 1632;
const int kindGitStatusDraft = 1633;

const int _assignmentPageLimit = 500;
const int _relayMaxPageLimit = 1000;
const int _issueIdChunkSize = 100;

class ProjectIssueStatus {
  static const triage = 'Triage';
  static const backlog = 'Backlog';
  static const inProgress = 'In Progress';
  static const inReview = 'In Review';
  static const done = 'Done';
  static const closed = 'Closed';
}

class ProjectIssueComment {
  final String id;
  final String content;
  final List<List<String>> tags;
  final String author;
  final int createdAt;

  const ProjectIssueComment({
    required this.id,
    required this.content,
    required this.tags,
    required this.author,
    required this.createdAt,
  });
}

/// Issue read model reduced from kind:1621 root + status/comment events.
class ProjectIssue {
  final String id;
  final String title;
  final String content;
  final List<List<String>> tags;
  final String author;
  final int createdAt;
  final String? repoAddress;
  final String? channelId;
  final List<String> labels;
  final List<String> recipients;
  final List<String> assignees;
  final String status;
  final String? statusEventId;
  final int updatedAt;
  final List<ProjectIssueComment> comments;

  const ProjectIssue({
    required this.id,
    required this.title,
    required this.content,
    required this.tags,
    required this.author,
    required this.createdAt,
    required this.repoAddress,
    required this.channelId,
    required this.labels,
    required this.recipients,
    required this.assignees,
    required this.status,
    required this.statusEventId,
    required this.updatedAt,
    required this.comments,
  });
}

String? _tag(NostrEvent event, String name) => event.getTagValue(name);

List<String> _allTags(NostrEvent event, String name) => [
  for (final tag in event.tags)
    if (tag.length > 1 && tag[0] == name && tag[1].isNotEmpty) tag[1],
];

List<List<String>> _imetaTags(NostrEvent event) => [
  for (final tag in event.tags)
    if (tag.isNotEmpty && tag[0] == 'imeta') tag,
];

final RegExp _hex64 = RegExp(r'^[a-fA-F0-9]{64}$');

String? _repoOwnerFromAddress(String? repoAddress) {
  final parts = (repoAddress ?? '').split(':');
  if (parts.length < 2) return null;
  final owner = parts[1];
  return _hex64.hasMatch(owner) ? owner.toLowerCase() : null;
}

/// Pubkeys allowed to change a root event's lifecycle (status, updates):
/// the root author and the owner of the repo the root event targets.
Set<String> allowedActorsForRoot(NostrEvent rootEvent) {
  final allowed = <String>{rootEvent.pubkey.toLowerCase()};
  final owner = _repoOwnerFromAddress(_tag(rootEvent, 'a'));
  if (owner != null) allowed.add(owner);
  return allowed;
}

/// (created_at, id) ascending — matches desktop `sortEvents`.
List<NostrEvent> _sortEvents(List<NostrEvent> events) {
  final sorted = [...events]
    ..sort((left, right) {
      final byTime = left.createdAt.compareTo(right.createdAt);
      if (byTime != 0) return byTime;
      return left.id.compareTo(right.id);
    });
  return sorted;
}

NostrEvent? _latestStatusForIssue(
  NostrEvent issue,
  List<NostrEvent> statusEvents,
) {
  final allowedActors = allowedActorsForRoot(issue);
  NostrEvent? latest;
  for (final event in statusEvents) {
    if (!allowedActors.contains(event.pubkey.toLowerCase())) continue;
    final references = event.tags.any(
      (tag) => tag.length > 1 && tag[0] == 'e' && tag[1] == issue.id,
    );
    if (!references) continue;
    if (latest == null || event.createdAt > latest.createdAt) latest = event;
  }
  return latest;
}

String _statusFromEvent(NostrEvent issue, NostrEvent? statusEvent) {
  if (statusEvent != null) {
    if (statusEvent.kind == kindGitStatusMerged) return ProjectIssueStatus.done;
    if (statusEvent.kind == kindGitStatusClosed) {
      return ProjectIssueStatus.closed;
    }
    // NIP-34 calls 1633 "Draft"; surfaced as Triage for issues.
    if (statusEvent.kind == kindGitStatusDraft) {
      return ProjectIssueStatus.triage;
    }
  }
  final labels = [
    for (final label in _allTags(issue, 't')) label.toLowerCase(),
  ];
  if (labels.contains('in-review') || labels.contains('review')) {
    return ProjectIssueStatus.inReview;
  }
  if (labels.contains('in-progress') || labels.contains('active')) {
    return ProjectIssueStatus.inProgress;
  }
  if (labels.contains('triage')) return ProjectIssueStatus.triage;
  return ProjectIssueStatus.backlog;
}

class _AssignmentState {
  final List<String> assignees;
  const _AssignmentState(this.assignees);
}

/// Assignment state reduced from trusted kind:1 operations
/// (`t: assignment` adds each `p` tag; `t: unassignment` removes it).
/// Trusted signers: issue author + repo owner (anyone), plus community
/// members operating only on themselves. Ordering: uncaused self-service
/// first, authoritative second, causal self-service last — so signer
/// timestamps cannot override authority but a later owner/author decision
/// can be superseded by the affected assignee.
_AssignmentState _assignmentStateForIssue(
  NostrEvent issue,
  List<NostrEvent> issueCommentEvents,
) {
  final allowedActors = allowedActorsForRoot(issue);
  final assignees = <String>{};
  final operationHeads = <String, String>{};
  final uncausedSelfService = <_AssignmentOperation>[];
  final authoritative = <_AssignmentOperation>[];
  final causalSelfService = <_AssignmentOperation>[];
  final events = _sortEvents([
    for (final event in issueCommentEvents)
      if (event.kind == 1 &&
          event.tags.any(
            (tag) => tag.length > 1 && tag[0] == 'e' && tag[1] == issue.id,
          ))
        event,
  ]);
  for (final event in events) {
    final labels = _allTags(event, 't');
    final isAssignment = labels.contains(issueAssignmentLabel);
    final isUnassignment = labels.contains(issueUnassignmentLabel);
    if (isAssignment == isUnassignment) continue;
    final signer = event.pubkey.toLowerCase();
    final pubkeys = [
      for (final pubkey in _allTags(event, 'p')) pubkey.toLowerCase(),
    ];
    final isSelfOperation = pubkeys.length == 1 && pubkeys[0] == signer;
    if (!allowedActors.contains(signer) && !isSelfOperation) continue;
    final operation = _AssignmentOperation(
      id: event.id.toLowerCase(),
      isAssignment: isAssignment,
      pubkeys: pubkeys,
    );
    if (allowedActors.contains(signer)) {
      authoritative.add(operation);
    } else {
      final priorTags = [
        for (final tag in event.tags)
          if (tag.isNotEmpty && tag[0] == 'prior') tag,
      ];
      if (priorTags.isEmpty) {
        uncausedSelfService.add(operation);
        continue;
      }
      if (priorTags.length != 1 ||
          priorTags[0].length < 2 ||
          priorTags[0][1].isEmpty ||
          !_hex64.hasMatch(priorTags[0][1])) {
        continue;
      }
      causalSelfService.add(
        _AssignmentOperation(
          id: operation.id,
          isAssignment: operation.isAssignment,
          pubkeys: operation.pubkeys,
          prior: priorTags[0][1].toLowerCase(),
        ),
      );
    }
  }
  for (final operation in [
    ...uncausedSelfService,
    ...authoritative,
    ...causalSelfService,
  ]) {
    if (operation.prior != null &&
        operationHeads[operation.pubkeys[0]] != operation.prior) {
      continue;
    }
    for (final pubkey in operation.pubkeys) {
      if (operation.isAssignment) {
        assignees.add(pubkey);
      } else {
        assignees.remove(pubkey);
      }
      operationHeads[pubkey] = operation.id;
    }
  }
  return _AssignmentState(assignees.toList());
}

class _AssignmentOperation {
  final String id;
  final bool isAssignment;
  final List<String> pubkeys;
  final String? prior;
  const _AssignmentOperation({
    required this.id,
    required this.isAssignment,
    required this.pubkeys,
    this.prior,
  });
}

List<ProjectIssueComment> _commentsForIssue(List<NostrEvent> events) {
  return [
    for (final event in _sortEvents(events))
      ProjectIssueComment(
        id: event.id,
        content: event.content,
        tags: _imetaTags(event),
        author: event.pubkey,
        createdAt: event.createdAt,
      ),
  ];
}

ProjectIssue eventToProjectIssue(
  NostrEvent issue, {
  List<NostrEvent> statusEvents = const [],
  List<NostrEvent> commentEvents = const [],
}) {
  final latestStatus = _latestStatusForIssue(issue, statusEvents);
  final issueCommentEvents = [
    for (final event in commentEvents)
      if (event.tags.any(
        (tag) =>
            tag.length > 1 &&
            (tag[0] == 'e' || tag[0] == 'E') &&
            tag[1] == issue.id,
      ))
        event,
  ];
  final comments = _commentsForIssue(issueCommentEvents);
  final assignmentState = _assignmentStateForIssue(issue, issueCommentEvents);
  final labels = _allTags(issue, 't');
  var title =
      _tag(issue, 'subject') ??
      (issue.content.contains('\n')
          ? issue.content.split('\n').first
          : issue.content);
  if (title.isEmpty) title = 'Untitled task';

  var updatedAt = issue.createdAt;
  for (final comment in comments) {
    if (comment.createdAt > updatedAt) updatedAt = comment.createdAt;
  }
  if (latestStatus != null && latestStatus.createdAt > updatedAt) {
    updatedAt = latestStatus.createdAt;
  }

  return ProjectIssue(
    id: issue.id,
    title: title,
    content: issue.content,
    tags: _imetaTags(issue),
    author: issue.pubkey,
    createdAt: issue.createdAt,
    repoAddress: _tag(issue, 'a'),
    channelId: _tag(issue, 'h'),
    labels: labels,
    recipients: _allTags(issue, 'p'),
    assignees: assignmentState.assignees,
    status: _statusFromEvent(issue, latestStatus),
    statusEventId: latestStatus?.id,
    updatedAt: updatedAt,
    comments: comments,
  );
}

List<ProjectIssue> projectIssueEventsToIssues({
  required List<NostrEvent> issueEvents,
  List<NostrEvent> statusEvents = const [],
  List<NostrEvent> commentEvents = const [],
}) {
  final issues = [
    for (final issue in issueEvents)
      eventToProjectIssue(
        issue,
        statusEvents: statusEvents,
        commentEvents: commentEvents,
      ),
  ]..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  return issues;
}

typedef RelayFetch = Future<List<NostrEvent>> Function(NostrFilter filter);

bool _isAssignmentOperation(NostrEvent event) => event.tags.any(
  (tag) =>
      tag.length > 1 &&
      tag[0] == 't' &&
      (tag[1] == issueAssignmentLabel || tag[1] == issueUnassignmentLabel),
);

/// Loads every assignment/unassignment operation for the given issues,
/// paginating to exhaustion (see desktop `fetchAssignmentOperationEvents`).
/// Only SQL-pushed constraints (kinds, #e, until, limit) go in the filter;
/// assignment labels are filtered locally.
Future<List<NostrEvent>> fetchAssignmentOperationEvents(
  RelayFetch fetch,
  List<String> issueIds,
) async {
  if (issueIds.isEmpty) return [];
  final pages = <List<NostrEvent>>[];
  for (var i = 0; i < issueIds.length; i += _issueIdChunkSize) {
    final end = (i + _issueIdChunkSize > issueIds.length)
        ? issueIds.length
        : i + _issueIdChunkSize;
    pages.add(
      await _fetchIssueCommentsExhaustively(fetch, issueIds.sublist(i, end)),
    );
  }
  final seen = <String, NostrEvent>{};
  for (final page in pages) {
    for (final event in page) {
      if (_isAssignmentOperation(event) && !seen.containsKey(event.id)) {
        seen[event.id] = event;
      }
    }
  }
  return seen.values.toList();
}

Future<List<NostrEvent>> _fetchIssueCommentsExhaustively(
  RelayFetch fetch,
  List<String> issueIds,
) async {
  final seen = <String, NostrEvent>{};
  var limit = _assignmentPageLimit;
  int? until;
  while (true) {
    final page = await fetch(
      NostrFilter(
        kinds: [1],
        tags: {'#e': issueIds},
        limit: limit,
        until: until,
      ),
    );
    for (final event in page) {
      if (!seen.containsKey(event.id)) seen[event.id] = event;
    }
    // Only SQL-pushed constraints are in the filter, so a short page is a
    // true end-of-results signal.
    if (page.length < limit) break;
    var oldest = page.first.createdAt;
    for (final event in page) {
      if (event.createdAt < oldest) oldest = event.createdAt;
    }
    if (until == null || oldest < until) {
      until = oldest;
      continue;
    }
    if (limit < _relayMaxPageLimit) {
      limit = _relayMaxPageLimit;
      continue;
    }
    throw StateError(
      'Could not load assignment history: more than a full relay page of '
      'issue comments share one timestamp.',
    );
  }
  return seen.values.toList();
}

/// Merge two event lists, dropping duplicates by event id.
List<NostrEvent> mergeEventsById(
  List<NostrEvent> base,
  List<NostrEvent> extra,
) {
  final ids = <String>{for (final event in base) event.id};
  return [
    ...base,
    for (final event in extra)
      if (!ids.contains(event.id)) event,
  ];
}

/// Aggregate issue fetch result for one repository.
class RepoIssuesResult {
  final List<ProjectIssue> issues;
  final List<NostrEvent> rootEvents;
  final List<NostrEvent> commentEvents;
  final List<NostrEvent> statusEvents;

  const RepoIssuesResult({
    required this.issues,
    required this.rootEvents,
    required this.commentEvents,
    required this.statusEvents,
  });
}
