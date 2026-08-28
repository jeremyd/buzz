// Port of desktop projectIssues.test.mjs (read-path subset).
import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/features/projects/project_issues.dart';
import 'package:buzz/features/projects/project_issue_mutations.dart';
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
  final author = 'b' * 64;
  final attacker = 'c' * 64;
  final repoAddress = '30617:$owner:demo';

  NostrEvent issueEvent({
    List<List<String>>? tags,
    String content = 'Something is broken',
  }) => _event(
    kind: 1621,
    pubkey: author,
    createdAt: 100,
    content: content,
    id: 'e' * 64,
    tags:
        tags ??
        [
          ['a', repoAddress],
          ['subject', 'Something is broken'],
        ],
  );

  NostrEvent statusEvent(int kind, String pubkey, int createdAt) => _event(
    kind: kind,
    pubkey: pubkey,
    createdAt: createdAt,
    id: 'status-${pubkey.substring(0, 8)}-$createdAt',
    tags: [
      ['e', 'e' * 64, '', 'root'],
      ['a', repoAddress],
    ],
  );

  NostrEvent assignmentComment(
    String pubkey,
    List<String> assignees,
    String id, {
    String label = issueAssignmentLabel,
    int createdAt = 200,
    String? prior,
  }) => _event(
    kind: 1,
    pubkey: pubkey,
    createdAt: createdAt,
    id: id,
    content: label == issueAssignmentLabel
        ? 'Assigned this issue'
        : 'Unassigned this issue',
    tags: [
      ['e', 'e' * 64, '', 'root'],
      ['a', repoAddress],
      for (final value in assignees) ['p', value],
      ['t', label],
      if (prior != null) ['prior', prior],
    ],
  );

  group('eventToProjectIssue', () {
    test('ignores status events from a different pubkey', () {
      final issue = eventToProjectIssue(
        issueEvent(),
        statusEvents: [statusEvent(1632, attacker, 300)],
      );
      expect(issue.status, ProjectIssueStatus.backlog);
    });

    test('honors status events from the issue author and repo owner', () {
      expect(
        eventToProjectIssue(
          issueEvent(),
          statusEvents: [statusEvent(1631, author, 300)],
        ).status,
        ProjectIssueStatus.done,
      );
      expect(
        eventToProjectIssue(
          issueEvent(),
          statusEvents: [statusEvent(1632, owner, 300)],
        ).status,
        ProjectIssueStatus.closed,
      );
      expect(
        eventToProjectIssue(
          issueEvent(),
          statusEvents: [statusEvent(1633, author, 300)],
        ).status,
        ProjectIssueStatus.triage,
      );
    });

    test('label fallbacks derive in-review / in-progress / triage', () {
      NostrEvent withLabels(List<String> labels) => issueEvent(
        tags: [
          ['a', repoAddress],
          ['subject', 'S'],
          for (final label in labels) ['t', label],
        ],
      );
      expect(
        eventToProjectIssue(withLabels(['in-review'])).status,
        ProjectIssueStatus.inReview,
      );
      expect(
        eventToProjectIssue(withLabels(['Review'])).status,
        ProjectIssueStatus.inReview,
      );
      expect(
        eventToProjectIssue(withLabels(['in-progress'])).status,
        ProjectIssueStatus.inProgress,
      );
      expect(
        eventToProjectIssue(withLabels(['active'])).status,
        ProjectIssueStatus.inProgress,
      );
      expect(
        eventToProjectIssue(withLabels(['triage'])).status,
        ProjectIssueStatus.triage,
      );
      expect(
        eventToProjectIssue(withLabels(['bug'])).status,
        ProjectIssueStatus.backlog,
      );
    });

    test('tag helpers drop malformed value-less tags', () {
      final event = issueEvent(
        tags: [
          ['a', repoAddress],
          ['t'],
          ['t', ''],
          ['t', 'bug'],
          ['p'],
          ['subject'],
        ],
      );
      final issue = eventToProjectIssue(event);
      expect(issue.labels, ['bug']);
      expect(issue.recipients, isEmpty);
      expect(issue.title, 'Something is broken');
      expect(issue.status, ProjectIssueStatus.backlog);
    });

    test('preserves root and comment imeta tags for rich rendering', () {
      final root = issueEvent(
        tags: [
          ['a', repoAddress],
          ['subject', 'Something is broken'],
          ['imeta', 'url https://relay.example/media/root.png', 'm image/png'],
        ],
      );
      final comment = _event(
        kind: 1,
        pubkey: attacker,
        createdAt: 200,
        id: 'comment-rich-content',
        content: '![Screenshot](https://relay.example/media/comment.png)',
        tags: [
          ['e', root.id, '', 'root'],
          [
            'imeta',
            'url https://relay.example/media/comment.png',
            'm image/png',
          ],
        ],
      );

      final issue = eventToProjectIssue(root, commentEvents: [comment]);

      expect(issue.tags, [
        ['imeta', 'url https://relay.example/media/root.png', 'm image/png'],
      ]);
      expect(issue.comments.single.tags, [
        ['imeta', 'url https://relay.example/media/comment.png', 'm image/png'],
      ]);
    });

    test('title falls back to first content line then Untitled task', () {
      expect(
        eventToProjectIssue(
          issueEvent(
            tags: [
              ['a', repoAddress],
            ],
          ),
        ).title,
        'Something is broken',
      );
      expect(
        eventToProjectIssue(
          issueEvent(
            tags: [
              ['a', repoAddress],
            ],
            content: '',
          ),
        ).title,
        'Untitled task',
      );
    });
    test('updatedAt is the latest of root, comments, and status', () {
      final comment = _event(
        kind: 1,
        pubkey: author,
        createdAt: 250,
        id: 'comment-late',
        content: 'Late',
        tags: [
          ['e', 'e' * 64, '', 'root'],
        ],
      );
      expect(
        eventToProjectIssue(issueEvent(), commentEvents: [comment]).updatedAt,
        250,
      );
      expect(
        eventToProjectIssue(
          issueEvent(),
          statusEvents: [statusEvent(1631, author, 300)],
          commentEvents: [comment],
        ).updatedAt,
        300,
      );
    });

    test('assignees follow trusted assignment operations in order', () {
      final assignee = 'd' * 64;
      final otherAssignee = 'f' * 64;
      final volunteer = '5' * 64;

      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          assignmentComment(author, [
            assignee.toUpperCase(),
            author,
          ], 'assign-1'),
          assignmentComment(owner, [assignee, otherAssignee], 'assign-2'),
          assignmentComment(volunteer, [volunteer], 'assign-3'),
          // Untrusted signer assigning someone else — ignored.
          assignmentComment(attacker, ['a' * 64], 'assign-4'),
          // Untrusted signer sneaking themselves in — ignored.
          assignmentComment(attacker, [attacker, 'b' * 64], 'assign-5'),
          // A volunteer may remove only themselves.
          assignmentComment(
            volunteer,
            [volunteer],
            'unassign-1',
            label: issueUnassignmentLabel,
            createdAt: 201,
          ),
          // An untrusted signer cannot remove somebody else.
          assignmentComment(
            attacker,
            [otherAssignee],
            'unassign-2',
            label: issueUnassignmentLabel,
            createdAt: 202,
          ),
          // Repo owner may remove any assignee.
          assignmentComment(
            owner,
            [otherAssignee],
            'unassign-3',
            label: issueUnassignmentLabel,
            createdAt: 203,
          ),
          // Same-second tie-break by event id: 'a-assign' < 'z-unassign',
          // so the assign sorts first and the unassign removes them.
          assignmentComment(owner, [otherAssignee], 'a-assign', createdAt: 204),
          assignmentComment(
            owner,
            [otherAssignee],
            'z-unassign',
            label: issueUnassignmentLabel,
            createdAt: 204,
          ),
          // Trusted plain comment without the label adds nothing.
          _event(
            kind: 1,
            pubkey: author,
            createdAt: 201,
            id: 'plain-comment',
            content: 'Just a comment',
            tags: [
              ['e', 'e' * 64, '', 'root'],
              ['p', attacker],
            ],
          ),
        ],
      );

      expect(issue.assignees.toSet(), {author, assignee});
    });

    test('owner unassignment overrides a future-dated self-assignment', () {
      final volunteer = '5' * 64;
      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          assignmentComment(
            volunteer,
            [volunteer],
            'future-self-assign',
            createdAt: 1000,
          ),
          assignmentComment(
            owner,
            [volunteer],
            'owner-unassign',
            label: issueUnassignmentLabel,
            createdAt: 200,
          ),
        ],
      );
      expect(issue.assignees, isEmpty);
    });

    test('owner assignment overrides a future-dated self-unassignment', () {
      final volunteer = '5' * 64;
      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          assignmentComment(
            volunteer,
            [volunteer],
            'future-self-unassign',
            label: issueUnassignmentLabel,
            createdAt: 1000,
          ),
          assignmentComment(owner, [volunteer], 'owner-assign', createdAt: 200),
        ],
      );
      expect(issue.assignees, [volunteer]);
    });

    test('causal self-unassignment can follow an owner assignment', () {
      final volunteer = '5' * 64;
      final ownerAssignmentId = '1' * 64;
      final selfUnassignmentId = '2' * 64;
      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          assignmentComment(owner, [volunteer], ownerAssignmentId),
          assignmentComment(
            volunteer,
            [volunteer],
            selfUnassignmentId,
            label: issueUnassignmentLabel,
            createdAt: 300,
            prior: ownerAssignmentId,
          ),
        ],
      );
      expect(issue.assignees, isEmpty);
    });

    test('causal self-assignment can follow an owner unassignment', () {
      final volunteer = '5' * 64;
      final ownerUnassignmentId = '3' * 64;
      final selfAssignmentId = '4' * 64;
      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          assignmentComment(
            owner,
            [volunteer],
            ownerUnassignmentId,
            label: issueUnassignmentLabel,
          ),
          assignmentComment(
            volunteer,
            [volunteer],
            selfAssignmentId,
            createdAt: 300,
            prior: ownerUnassignmentId,
          ),
        ],
      );
      expect(issue.assignees, [volunteer]);
    });

    test('ignores a causal self-operation with a stale prior', () {
      final volunteer = '5' * 64;
      final initialAssignmentId = '6' * 64;
      final ownerUnassignmentId = '7' * 64;
      final staleSelfAssignmentId = '8' * 64;
      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          assignmentComment(owner, [volunteer], initialAssignmentId),
          assignmentComment(
            owner,
            [volunteer],
            ownerUnassignmentId,
            label: issueUnassignmentLabel,
            createdAt: 250,
          ),
          assignmentComment(
            volunteer,
            [volunteer],
            staleSelfAssignmentId,
            createdAt: 300,
            prior: initialAssignmentId,
          ),
        ],
      );
      expect(issue.assignees, isEmpty);
    });

    test('issue recipients remain notification routing, not assignments', () {
      final issue = eventToProjectIssue(
        issueEvent(
          tags: [
            ['a', repoAddress],
            ['subject', 'Something is broken'],
            ['p', owner],
            ['p', ('d' * 64).toUpperCase()],
            ['p', 'f' * 64],
          ],
        ),
      );
      expect(issue.recipients.length, 3);
      expect(issue.assignees, isEmpty);
    });

    test('comments sort ascending by (created_at, id)', () {
      final issue = eventToProjectIssue(
        issueEvent(),
        commentEvents: [
          _event(
            kind: 1,
            pubkey: author,
            createdAt: 201,
            id: 'comment-2',
            content: 'Second',
            tags: [
              ['e', 'e' * 64, '', 'root'],
            ],
          ),
          _event(
            kind: 1,
            pubkey: author,
            createdAt: 200,
            id: 'comment-1',
            content: 'First',
            tags: [
              ['e', 'e' * 64, '', 'root'],
            ],
          ),
        ],
      );
      expect(issue.comments.map((comment) => comment.content).toList(), [
        'First',
        'Second',
      ]);
    });
  });

  group('projectIssueEventsToIssues', () {
    test('sorts issues by updatedAt descending', () {
      final older = issueEvent();
      final newer = _event(
        kind: 1621,
        pubkey: author,
        createdAt: 500,
        id: 'f' * 64,
        content: 'Newer task',
        tags: [
          ['a', repoAddress],
          ['subject', 'Newer task'],
        ],
      );
      final issues = projectIssueEventsToIssues(issueEvents: [older, newer]);
      expect(issues.first.id, 'f' * 64);
    });
  });

  group('fetchAssignmentOperationEvents', () {
    test('paginates by until cursor and filters locally', () async {
      final pageOne = [
        for (var i = 0; i < 2; i++)
          _event(
            kind: 1,
            pubkey: author,
            createdAt: 100 + i,
            id: 'op-$i',
            tags: [
              ['e', 'e' * 64, '', 'root'],
              ['t', issueAssignmentLabel],
              ['p', 'd' * 64],
            ],
          ),
        // Comment without assignment label — filtered out.
        _event(
          kind: 1,
          pubkey: author,
          createdAt: 50,
          id: 'plain',
          tags: [
            ['e', 'e' * 64, '', 'root'],
          ],
        ),
      ];
      final calls = <NostrFilter>[];
      await fetchAssignmentOperationEvents((filter) async {
        calls.add(filter);
        // Full 500-page (padded), then short page ends the walk.
        if (calls.length == 1) {
          return [
            ...pageOne,
            for (var i = 0; i < 497; i++)
              _event(
                kind: 1,
                pubkey: author,
                createdAt: 100,
                id: 'filler-${i.toString().padLeft(4, '0')}',
                tags: [
                  ['e', 'e' * 64, '', 'root'],
                ],
              ),
          ];
        }
        return [];
      }, ['e' * 64]);

      expect(calls.length, 2);
      expect(calls[0].until, isNull);
      // Cursor advanced to the oldest event in the full first page.
      expect(calls[1].until, 50);
      expect(calls[1].tags['#e'], ['e' * 64]);
    });

    test('returns empty for no issue ids', () async {
      var called = false;
      final result = await fetchAssignmentOperationEvents((filter) async {
        called = true;
        return [];
      }, []);
      expect(result, isEmpty);
      expect(called, isFalse);
    });
  });

  group('mergeEventsById', () {
    test('drops duplicates by event id, first occurrence wins', () {
      final a = _event(
        kind: 1,
        pubkey: author,
        createdAt: 100,
        id: 'dup',
        tags: [],
      );
      final b = _event(
        kind: 1,
        pubkey: owner,
        createdAt: 200,
        id: 'unique',
        tags: [],
      );
      final merged = mergeEventsById([a, b], [a, b]);
      expect(merged.map((event) => event.id).toList(), ['dup', 'unique']);
    });
  });

  group('buildGitIssueTags', () {
    test('builds repository-scoped issue creation tags', () {
      expect(
        buildGitIssueTags(
          repoAddress: repoAddress,
          repoOwner: owner,
          title: '  Fix the broken workflow  ',
        ),
        [
          ['a', repoAddress],
          ['p', owner],
          ['subject', 'Fix the broken workflow'],
        ],
      );
    });

    test('rejects non-30617 repos, bad owners, and bad titles', () {
      expect(
        () => buildGitIssueTags(
          repoAddress: '30621:$owner:x',
          repoOwner: owner,
          title: 'T',
        ),
        throwsArgumentError,
      );
      expect(
        () => buildGitIssueTags(
          repoAddress: repoAddress,
          repoOwner: 'short',
          title: 'T',
        ),
        throwsArgumentError,
      );
      expect(
        () => buildGitIssueTags(
          repoAddress: repoAddress,
          repoOwner: owner,
          title: '   ',
        ),
        throwsArgumentError,
      );
      expect(
        () => buildGitIssueTags(
          repoAddress: repoAddress,
          repoOwner: owner,
          title: 'x' * 257,
        ),
        throwsArgumentError,
      );
    });
  });

  group('nextProjectIssueCommentCreatedAt', () {
    test('orders consecutive same-author comments across whole seconds', () {
      final comment = _event(
        kind: 1,
        pubkey: author,
        createdAt: 200,
        id: 'comment-1',
        content: 'First',
        tags: [
          ['e', 'e' * 64, '', 'root'],
        ],
      );
      final issue = eventToProjectIssue(issueEvent(), commentEvents: [comment]);
      expect(nextProjectIssueCommentCreatedAt(issue, 150, author), 201);
      expect(nextProjectIssueCommentCreatedAt(issue, 500, author), 500);
      // Other authors' comments do not constrain this author.
      expect(nextProjectIssueCommentCreatedAt(issue, 150, owner), 150);
    });
  });
}
