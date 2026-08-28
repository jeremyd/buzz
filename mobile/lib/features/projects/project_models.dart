/// Read models for NIP-34 projects and repositories.
///
/// Faithful port of `desktop/src/features/projects/projectModels.ts`
/// (buildProjectReadModels / eventToRepository / eventToExplicitProject).
/// Keep the parsing rules in sync with the desktop implementation.
library;

import '../../shared/relay/relay.dart';

/// Repository read model parsed from a kind:30617 repo announcement.
class ProjectRepository {
  final String id;
  final String dtag;
  final String name;
  final String description;
  final String owner;
  final String repoAddress;
  final String? webUrl;
  final List<String> cloneUrls;
  final int createdAt;
  final String status;
  final String defaultBranch;
  final String? channelId;

  const ProjectRepository({
    required this.id,
    required this.dtag,
    required this.name,
    required this.description,
    required this.owner,
    required this.repoAddress,
    required this.webUrl,
    required this.cloneUrls,
    required this.createdAt,
    required this.status,
    required this.defaultBranch,
    required this.channelId,
  });
}

/// Project read model parsed from a kind:30621 project announcement.
class Project {
  final String id;
  final String dtag;
  final String name;
  final String description;
  final String owner;
  final int createdAt;
  final String projectAddress;
  final String? projectChannelId;
  final String status;
  final List<String> repositoryAddresses;
  final List<ProjectRepository> repositories;
  final List<String> unavailableRepositoryAddresses;
  final bool legacy;

  const Project({
    required this.id,
    required this.dtag,
    required this.name,
    required this.description,
    required this.owner,
    required this.createdAt,
    required this.projectAddress,
    required this.projectChannelId,
    required this.status,
    required this.repositoryAddresses,
    required this.repositories,
    required this.unavailableRepositoryAddresses,
    required this.legacy,
  });
}

const int _kindRepoAnnouncement = 30617;
const int _kindProjectAnnouncement = 30621;
const int _maxDTagBytes = 1024;

bool _isValidPubkey(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

bool _isValidDTag(String value) {
  final bytes = value.codeUnits;
  return bytes.isNotEmpty && bytes.length <= _maxDTagBytes;
}

String? _tag(NostrEvent event, String name) {
  for (final tag in event.tags) {
    if (tag.isNotEmpty &&
        tag[0] == name &&
        tag.length > 1 &&
        tag[1].isNotEmpty) {
      return tag[1];
    }
  }
  return null;
}

List<String> _allTags(NostrEvent event, String name) => [
  for (final tag in event.tags)
    if (tag.isNotEmpty && tag[0] == name && tag.length > 1 && tag[1].isNotEmpty)
      tag[1],
];

bool _isValidProjectChannelId(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(value);

/// Latest-addressable-event dedup: highest created_at wins, event id breaks
/// ties (matches desktop `deduplicateAddressableEvents`).
Map<String, NostrEvent> _deduplicateAddressable(List<NostrEvent> events) {
  final byAddress = <String, NostrEvent>{};
  for (final event in events) {
    final dtag = _tag(event, 'd');
    if (dtag == null) continue;
    final address = '${event.kind}:${event.pubkey.toLowerCase()}:$dtag';
    final existing = byAddress[address];
    if (existing == null ||
        event.createdAt > existing.createdAt ||
        (event.createdAt == existing.createdAt &&
            event.id.compareTo(existing.id) > 0)) {
      byAddress[address] = event;
    }
  }
  return byAddress;
}

ProjectRepository? eventToRepository(NostrEvent event) {
  final dtag = _tag(event, 'd');
  if (event.kind != _kindRepoAnnouncement ||
      dtag == null ||
      !_isValidDTag(dtag) ||
      !_isValidPubkey(event.pubkey)) {
    return null;
  }
  final owner = event.pubkey.toLowerCase();
  final channel = _tag(event, 'buzz-channel');
  return ProjectRepository(
    id: '$owner:$dtag',
    dtag: dtag,
    name: _tag(event, 'name') ?? dtag,
    description: _tag(event, 'description') ?? event.content,
    owner: owner,
    repoAddress: '$_kindRepoAnnouncement:$owner:$dtag',
    webUrl: _tag(event, 'web'),
    cloneUrls: [
      for (final tag in event.tags)
        if (tag.isNotEmpty && tag[0] == 'clone')
          for (var i = 1; i < tag.length; i++)
            if (tag[i].isNotEmpty) tag[i],
    ],
    createdAt: event.createdAt,
    status: _tag(event, 'status') ?? 'active',
    defaultBranch: _tag(event, 'default-branch') ?? 'main',
    channelId: channel != null && _isValidProjectChannelId(channel)
        ? channel
        : null,
  );
}

Project? _eventToExplicitProject(
  NostrEvent event,
  Map<String, ProjectRepository> repositoriesByAddress,
  Map<String, ProjectRepository> visibleRepositoriesByAddress,
) {
  if (event.kind != _kindProjectAnnouncement || !_isValidPubkey(event.pubkey)) {
    return null;
  }
  final dtag = _tag(event, 'd') ?? '';
  if (dtag.isEmpty) return null;

  final repositoryAddresses = [
    for (final tag in event.tags)
      if (tag.isNotEmpty &&
          tag[0] == 'a' &&
          tag.length > 1 &&
          tag[1].isNotEmpty)
        tag[1],
  ]..sort();
  final owner = event.pubkey.toLowerCase();
  final projectAddress = '$_kindProjectAnnouncement:$owner:$dtag';
  final rawVisibility = _tag(event, 'buzz-visibility');
  final unlisted = rawVisibility == 'unlisted';
  if (unlisted) return null; // desktop filters listed-only
  final channel = _tag(event, 'buzz-channel');

  return Project(
    id: projectAddress,
    dtag: dtag,
    name: _tag(event, 'name') ?? dtag,
    description: _tag(event, 'description') ?? '',
    owner: owner,
    createdAt: event.createdAt,
    projectAddress: projectAddress,
    projectChannelId: channel != null && _isValidProjectChannelId(channel)
        ? channel
        : null,
    status: 'active',
    repositoryAddresses: repositoryAddresses,
    repositories: [
      for (final address in repositoryAddresses)
        if (visibleRepositoriesByAddress.containsKey(address))
          visibleRepositoriesByAddress[address]!,
    ],
    unavailableRepositoryAddresses: [
      for (final address in repositoryAddresses)
        if (!repositoriesByAddress.containsKey(address)) address,
    ],
    legacy: false,
  );
}

Project _repositoryToLegacyProject(ProjectRepository repository) => Project(
  id: repository.repoAddress,
  dtag: repository.dtag,
  name: repository.name,
  description: repository.description,
  owner: repository.owner,
  createdAt: repository.createdAt,
  projectAddress: repository.repoAddress,
  projectChannelId: repository.channelId,
  status: repository.status,
  repositoryAddresses: [repository.repoAddress],
  repositories: [repository],
  unavailableRepositoryAddresses: const [],
  legacy: true,
);

/// Builds the project list from announcement + tombstone events.
/// Port of desktop `buildProjectReadModels` (fail-closed tombstones handled
/// by the provider before calling this).
List<Project> buildProjectReadModels({
  required List<NostrEvent> projectEvents,
  required List<NostrEvent> repositoryEvents,
  List<NostrEvent> deletionEvents = const [],
}) {
  // NIP-09 tombstone thresholds per coordinate.
  final deletionThresholds = <String, int>{};
  for (final event in deletionEvents) {
    for (final target in _allTags(event, 'a')) {
      final parts = target.split(':');
      if (parts.length != 3) continue;
      final current = deletionThresholds[target];
      if (current == null || event.createdAt > current) {
        deletionThresholds[target] = event.createdAt;
      }
    }
  }
  bool isDeleted(NostrEvent event) {
    final dtag = _tag(event, 'd');
    if (dtag == null) return false;
    final coordinate = '${event.kind}:${event.pubkey.toLowerCase()}:$dtag';
    final threshold = deletionThresholds[coordinate];
    return threshold != null && event.createdAt <= threshold;
  }

  final repositories = _deduplicateAddressable(repositoryEvents).values
      .where((event) => !isDeleted(event))
      .map(eventToRepository)
      .whereType<ProjectRepository>()
      .toList();
  final repositoriesByAddress = {
    for (final repository in repositories) repository.repoAddress: repository,
  };

  final explicitProjects = _deduplicateAddressable(projectEvents).values
      .where((event) => !isDeleted(event))
      .map(
        (event) => _eventToExplicitProject(
          event,
          repositoriesByAddress,
          repositoriesByAddress,
        ),
      )
      .whereType<Project>()
      .toList();

  final claimedRepositories = <String>{};
  for (final project in explicitProjects) {
    for (final address in project.repositoryAddresses) {
      final repository = repositoriesByAddress[address];
      if (repository != null && repository.owner == project.owner) {
        claimedRepositories.add(address);
      }
    }
  }

  final legacyProjects = repositories
      .where(
        (repository) => !claimedRepositories.contains(repository.repoAddress),
      )
      .map(_repositoryToLegacyProject)
      .toList();

  return [...explicitProjects, ...legacyProjects]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
