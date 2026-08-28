/// Write operations for NIP-34 issues (create + assignment).
///
/// Port of desktop `issueMutations.ts` (publishProjectIssue) and
/// `issueAssignments.ts` (writeProjectIssueAssignment, non-managed-owner
/// path only). Status-change publishing is not part of the mobile scope
/// yet — desktop only reads 1630-1633 for issues.
library;

import '../../shared/relay/relay.dart';
import 'project_issues.dart';

const int _kindGitIssue = 1621;
const int _kindTextNote = 1;

final RegExp _hex64 = RegExp(r'^[a-fA-F0-9]{64}$');

/// Tags for a repository-scoped issue creation event
/// (port of desktop `buildGitIssueTags`).
List<List<String>> buildGitIssueTags({
  required String repoAddress,
  required String repoOwner,
  required String title,
  List<String> labels = const [],
}) {
  if (!repoAddress.startsWith('30617:')) {
    throw ArgumentError('Task repo address must reference a kind:30617 repo.');
  }
  if (!_hex64.hasMatch(repoOwner)) {
    throw ArgumentError('Repo owner must be 64 hex characters.');
  }
  final subject = title.trim();
  if (subject.isEmpty) {
    throw ArgumentError('Task title is required.');
  }
  if (subject.length > 256) {
    throw ArgumentError('Task title must be 256 characters or fewer.');
  }

  final tags = <List<String>>[
    ['a', repoAddress],
    ['p', repoOwner.toLowerCase()],
    ['subject', subject],
  ];
  for (final label in labels) {
    final trimmed = label.trim();
    if (trimmed.isNotEmpty) tags.add(['t', trimmed]);
  }
  return tags;
}

/// Creates a kind:1621 issue on the given repository. Returns the event id.
Future<String> publishProjectIssue(
  SignedEventRelay signedRelay, {
  required String repoAddress,
  required String repoOwner,
  required String title,
  required String body,
  String category = 'issue',
}) async {
  final result = await signedRelay.submit(
    kind: _kindGitIssue,
    content: body.trim(),
    tags: buildGitIssueTags(
      repoAddress: repoAddress,
      repoOwner: repoOwner,
      title: title,
      labels: [category],
    ),
  );
  return result.id;
}

/// Keep consecutive same-author comments ordered across whole-second Nostr
/// timestamps (port of desktop `nextProjectIssueCommentCreatedAt`).
int nextProjectIssueCommentCreatedAt(
  ProjectIssue issue,
  int now,
  String author,
) {
  final normalizedAuthor = author.toLowerCase();
  var latest = now;
  for (final comment in issue.comments) {
    if (comment.author.toLowerCase() != normalizedAuthor) continue;
    if (comment.createdAt + 1 > latest) latest = comment.createdAt + 1;
  }
  return latest;
}

/// Signs and publishes a kind:1 assignment/unassignment operation.
/// Mirrors desktop `writeProjectIssueAssignment` for the standard (non
/// managed-owner) path: the `prior` head is attached only for single-assignee
/// self-service operations so the causal chain stays verifiable.
Future<void> writeProjectIssueAssignment({
  required SignedEventRelay signedRelay,
  required String signerPubkey,
  required ProjectIssue issue,
  required String repoAddress,
  required List<String> assignees,
  required bool isAssignment,
  int? createdAt,
}) async {
  final unique = <String>{
    for (final pubkey in assignees) pubkey.toLowerCase(),
  }.toList();
  final content = isAssignment
      ? 'Assigned this task to ${unique.length} assignee(s)'
      : 'Unassigned ${unique.length} assignee(s) from this task';
  final label = isAssignment ? issueAssignmentLabel : issueUnassignmentLabel;
  final normalizedSigner = signerPubkey.toLowerCase();
  final String? prior = unique.length == 1 && unique[0] == normalizedSigner
      ? issue.assigneeOperationHeads[normalizedSigner]
      : null;

  await signedRelay.submit(
    kind: _kindTextNote,
    content: content,
    createdAt:
        createdAt ??
        nextProjectIssueCommentCreatedAt(
          issue,
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          normalizedSigner,
        ),
    tags: [
      ['e', issue.id, '', 'root'],
      ['a', repoAddress],
      for (final pubkey in unique) ['p', pubkey],
      ['t', label],
      if (prior != null) ['prior', prior],
    ],
  );
}
