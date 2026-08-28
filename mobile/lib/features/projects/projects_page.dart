/// Projects list — mobile read path for NIP-34 projects and repositories.
///
/// First section of the mobile parity work (issue 7ecab0be): browse projects,
/// their repositories, and task counts. Creation/status/assignment
/// interactions come in the second pass.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';
import '../../shared/widgets/bee_refresh_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import 'project_models.dart';
import 'projects_provider.dart';

class ProjectsPage extends HookConsumerWidget {
  const ProjectsPage({this.tabReselection, super.key});

  /// Notifies this page when its already-selected tab is tapped again.
  final ValueListenable<int>? tabReselection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);
    final selectedProject = useState<Project?>(null);

    void onReselect() {
      if (selectedProject.value != null) {
        selectedProject.value = null;
      }
    }

    useEffect(() {
      tabReselection?.addListener(onReselect);
      return () {
        tabReselection?.removeListener(onReselect);
      };
    }, [tabReselection]);

    final project = selectedProject.value;
    if (project != null) {
      return _ProjectDetailPage(
        project: project,
        onBack: () => selectedProject.value = null,
      );
    }

    return FrostedScaffold(
      appBar: FrostedAppBar(
        title: Text(
          'Projects',
          style: context.textTheme.titleMedium?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: projectsAsync.when(
        data: (projects) => BeeRefreshIndicator(
          onRefresh: () async {
            await ref.read(projectsProvider.notifier).refresh();
          },
          child: projects.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    Center(child: Text('No projects yet.')),
                  ],
                )
              : ListView.builder(
                  itemCount: projects.length,
                  itemBuilder: (context, index) {
                    final project = projects[index];
                    return _ProjectCard(
                      project: project,
                      onTap: () => selectedProject.value = project,
                    );
                  },
                ),
        ),
        error: (error, stackTrace) => _ProjectsError(
          error: error,
          onRetry: () => ref.read(projectsProvider.notifier).refresh(),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _ProjectsError extends StatelessWidget {
  const _ProjectsError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Grid.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not load projects',
              style: context.textTheme.titleMedium,
            ),
            const SizedBox(height: Grid.sm),
            Text(
              error.toString(),
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Grid.xs),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.onTap});

  final Project project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(
        project.legacy ? LucideIcons.gitBranch300 : LucideIcons.folder300,
      ),
      title: Text(
        project.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.titleSmall,
      ),
      subtitle: project.description.isEmpty
          ? null
          : Text(
              project.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
      trailing: project.repositories.isEmpty
          ? null
          : Text(
              '${project.repositories.length}',
              style: context.textTheme.labelMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
    );
  }
}

class _ProjectDetailPage extends StatelessWidget {
  const _ProjectDetailPage({required this.project, required this.onBack});

  final Project project;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return FrostedScaffold(
      appBar: FrostedAppBar(
        leading: BackButton(onPressed: onBack),
        title: Text(
          project.name,
          style: context.textTheme.titleMedium?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView(
        children: [
          if (project.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Grid.gutter,
                Grid.xs,
                Grid.gutter,
                0,
              ),
              child: Text(
                project.description,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: Grid.xs),
          if (project.repositories.isEmpty)
            const Padding(
              padding: EdgeInsets.all(Grid.gutter),
              child: Text('No repositories attached yet.'),
            )
          else
            for (final repository in project.repositories)
              ListTile(
                leading: const Icon(LucideIcons.gitBranch300),
                title: Text(repository.name),
                subtitle: Text(
                  repository.status == 'active'
                      ? repository.defaultBranch
                      : repository.status,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
          if (project.unavailableRepositoryAddresses.isNotEmpty)
            ListTile(
              leading: const Icon(LucideIcons.circleAlert300),
              title: Text(
                '${project.unavailableRepositoryAddresses.length} '
                'unavailable repositories',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
