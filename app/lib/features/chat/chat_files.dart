part of 'chat_screen.dart';

// File browser + preview screens, extracted from chat_screen.dart as a part so
// the hero file stays focused on chat. Shares the library's imports and
// private scope — behaviour is identical.

class _FileListScreen extends StatefulWidget {
  const _FileListScreen({required this.sessionId});

  final String sessionId;

  @override
  State<_FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<_FileListScreen> {
  final _searchController = TextEditingController();
  late Future<List<FileReference>> _files;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _files = _loadFiles();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<FileReference>> _loadFiles() {
    return context.read<BridgeClient>().listFiles(
          sessionId: widget.sessionId,
        );
  }

  void _refresh() {
    setState(() {
      _files = _loadFiles();
    });
  }

  void _openFile(FileReference reference) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FilePreviewScreen(
          sessionId: widget.sessionId,
          reference: reference,
        ),
      ),
    );
  }

  List<FileReference> _filtered(List<FileReference> files) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return files;
    return files.where((file) {
      final label = file.relativePath ?? file.name;
      return '$label ${file.language}'.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search files',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: _searchController.clear,
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<FileReference>>(
              future: _files,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _FilePreviewError(
                    message: snapshot.error.toString(),
                    onRetry: _refresh,
                  );
                }

                final files = _filtered(snapshot.data ?? const []);
                if (files.isEmpty) {
                  return _EmptyFileList(
                    message: _query.trim().isEmpty
                        ? 'No markdown or code files found.'
                        : 'No matching files.',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    _refresh();
                    await _files;
                  },
                  child: ListView.separated(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: files.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return ListTile(
                        leading: Icon(_fileIcon(file)),
                        title: Text(
                          file.relativePath ?? file.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_fileSubtitle(file)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openFile(file),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFileList extends StatelessWidget {
  const _EmptyFileList({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilePreviewScreen extends StatefulWidget {
  const _FilePreviewScreen({
    required this.sessionId,
    required this.reference,
  });

  final String sessionId;
  final FileReference reference;

  @override
  State<_FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<_FilePreviewScreen> {
  late Future<FilePreview> _preview;

  @override
  void initState() {
    super.initState();
    _preview = context.read<BridgeClient>().readFile(
          sessionId: widget.sessionId,
          path: widget.reference.path,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reference.name),
      ),
      body: FutureBuilder<FilePreview>(
        future: _preview,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _FilePreviewError(
              message: snapshot.error.toString(),
              onRetry: () {
                setState(() {
                  _preview = context.read<BridgeClient>().readFile(
                        sessionId: widget.sessionId,
                        path: widget.reference.path,
                      );
                });
              },
            );
          }
          final preview = snapshot.data;
          if (preview == null) {
            return _FilePreviewError(
              message: 'File preview is empty.',
              onRetry: () {
                setState(() {
                  _preview = context.read<BridgeClient>().readFile(
                        sessionId: widget.sessionId,
                        path: widget.reference.path,
                      );
                });
              },
            );
          }
          return _FilePreviewBody(
            sessionId: widget.sessionId,
            preview: preview,
          );
        },
      ),
    );
  }
}

class _FilePreviewBody extends StatelessWidget {
  const _FilePreviewBody({
    required this.sessionId,
    required this.preview,
  });

  final String sessionId;
  final FilePreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  preview.relativePath,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${preview.language} · ${formatBytes(preview.bytes)}',
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
        if (preview.truncated)
          Container(
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.all(8),
            child: const Text('Preview truncated because the file is large.'),
          ),
        Expanded(
          child: preview.isMarkdown
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _MarkdownMessage(
                    sessionId: sessionId,
                    text: preview.content,
                    onOpenFile: (reference) {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _FilePreviewScreen(
                            sessionId: sessionId,
                            reference: reference,
                          ),
                        ),
                      );
                    },
                  ),
                )
              : _CodePreview(content: preview.content),
        ),
      ],
    );
  }
}

class _CodePreview extends StatelessWidget {
  const _CodePreview({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            content,
            style: TextStyle(
              fontFamily: context.type.monoFamily,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilePreviewError extends StatelessWidget {
  const _FilePreviewError({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
