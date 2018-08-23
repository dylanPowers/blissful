import 'dart:io';

class SyncedFSNode {
  final bool binary;
  final String syncName;
  final String target;

  SyncedFSNode(this.target, this.syncName, [ this.binary = false ]);
  SyncedFSNode.same(String link, [binary = false]) :
      this(link, link, binary);

  factory SyncedFSNode.fromPrimitive(dynamic item, bool binary) {
    if (item is Map) {
      if (item.keys.length > 1 || item.keys.isEmpty) {
        throw "Invalid number of keys for map $item";
      }

      var k = item.keys.first as String;
      return new SyncedFSNode(k, item[k], binary);
    } else if (item is String) {
      return new SyncedFSNode.same(item, binary);
    }

    throw "Invalid fs node specifier ${item}";
  }

  String _workingDir;
  Uri _targetUri;
  Uri _syncUri;
  void _initURIs(String dotfilesPath, String installPath) {
    _workingDir = new Directory('.').resolveSymbolicLinksSync();
    _targetUri = new Uri.file("$_workingDir/${dotfilesPath}/${target}");
    _targetUri = _fileUriNormalize(_targetUri);
    _syncUri = _fileUriNormalize(new Uri.file("${installPath}/${syncName}"));
  }

  void link(String dotfilesPath, String installPath, dryRun) {
    _initURIs(dotfilesPath, installPath);

    var link = new Link.fromUri(_syncUri);
    var linkType = _fsTypeSync(_syncUri);

    if (linkType != FileSystemEntityType.NOT_FOUND &&
        (linkType != FileSystemEntityType.LINK || _isLinkValid(link))) {
      var currentTarget = new Uri.file(link.resolveSymbolicLinksSync());
      currentTarget = _fileUriNormalize(currentTarget);

      if (currentTarget != _targetUri) {
        _backupTarget(currentTarget, _targetUri, dryRun);
      } else {
        if (dryRun) print("Skipping ${link.path}. Already configured");
        return;
      }
    }

    if (FileStat.statSync(_targetUri.toFilePath()).type ==
        FileSystemEntityType.NOT_FOUND && !dryRun) {
      print("Skipping ${link.path}. Link and target don't exist");
      return;
    }

    _forceCreateLink(link, _syncUri, linkType, _targetUri, dryRun);
  }

  void cp(String dotfilesPath, String installPath, dryRun) {
    _initURIs(dotfilesPath, installPath);

    var existingF = new File.fromUri(_syncUri);
    var newF = new File.fromUri(_targetUri);
    var backupF = new File(_targetUri.toFilePath() + ".bak");
    var fileBackedUp = false;

    if (existingF.existsSync()) {
      if (dryRun) print("Backing up ${_syncUri.toFilePath()} to ${backupF.path}");
      else {
        backupF.parent.createSync(recursive: true);
        existingF.copySync("${backupF.path}");
      }

      fileBackedUp = true;
    }


    if (newF.existsSync()) {
      if (dryRun) print("Copying ${_targetUri.toFilePath()} to ${_syncUri.toFilePath()}");
      else {
        // We have to delete first because the file could be a symlink which
        // screws things up with Dart.
        _deletePath(_syncUri, _fsTypeSync(_syncUri));
        newF.copySync(_syncUri.toFilePath());

        // This is to allow read by others on copied files. It would be best
        // however to have a configuration option that allows for explicitly
        // setting the right permissions. This is an appropriate stop-gap
        // measure for the moment.
        Process.runSync('chmod', ['o+r', '${_syncUri.toFilePath()}']);
      }
    }

    if (fileBackedUp) {
      if (dryRun) print("Moving ${backupF.path} to ${_targetUri.toFilePath()}");
      else {
        backupF.renameSync(_targetUri.toFilePath());
      }
    }

    if (!existingF.existsSync() && !newF.existsSync()) {
      print("Skipping ${newF.path}. No files exist");
    }
  }

  @override
  String toString() => "$syncName -> $target";

  void _backupTarget(Uri currentTarget, Uri expectedTarget, bool dryRun) {
    var currentTargetType = _fsTypeSync(currentTarget);
    if (currentTargetType == FileSystemEntityType.FILE) {
      if (dryRun) print("Copy ${currentTarget.toFilePath()} to ${expectedTarget.toFilePath()}");
      else _copy(currentTarget, expectedTarget);
    } else if (currentTargetType == FileSystemEntityType.DIRECTORY) {
      if (dryRun) print("Copy recursively ${currentTarget.toFilePath()} to "
                        "${expectedTarget.toFilePath()}");
      else _copyDir(currentTarget, expectedTarget);
    }
  }

  void _copy(Uri fromUri, Uri toUri) {
    var from = new File.fromUri(fromUri);
    var to = new File.fromUri(toUri);
    if (!to.existsSync()) to.createSync(recursive: true);
    if (binary) Process.runSync('chmod', ['+x', '${toUri.toFilePath()}']);

    from.copySync(to.path);
  }

  void _copyDir(Uri fromUri, Uri toUri) {
    var to = new Directory.fromUri(toUri);
    if (!to.existsSync()) to.createSync(recursive: true);

    Process.runSync('cp', ['--recursive', '${fromUri.toFilePath()}/.', '${toUri.toFilePath()}']);
  }

  void _deletePath(Uri uri, FileSystemEntityType pathType) {
    switch (pathType) {
      case FileSystemEntityType.LINK:
        new Link.fromUri(uri).deleteSync();
        break;
      case FileSystemEntityType.FILE:
        new File.fromUri(uri).deleteSync();
        break;
      case FileSystemEntityType.DIRECTORY:
        new Directory.fromUri(uri).deleteSync(recursive: true);
        break;
    }
  }

  bool _isLinkValid(Link link) {
    try {
      link.resolveSymbolicLinksSync();
      return true;
    } on FileSystemException catch (e) {
      if (e.osError.errorCode == 2) {
        return false;
      } else rethrow;
    }
  }

  Uri _fileUriNormalize(Uri f) {
    var norm = f.normalizePath();
    if (norm.path.endsWith("/")) {
      norm = new Uri.file(norm.path.substring(0, norm.path.length - 1));
    }

    return norm;
  }

  void _forceCreateLink(Link link, Uri linkUri, FileSystemEntityType linkType,
                        Uri targetUri, bool dryRun) {
    try {
      if (linkType != FileSystemEntityType.NOT_FOUND) {
        if (dryRun) print("Delete ${link.path}");
        else _deletePath(linkUri, linkType);
      }

      if (dryRun) print("Link ${link.path} to ${targetUri.toFilePath()}");
      else link.createSync(targetUri.toFilePath(), recursive: true);
    } on FileSystemException catch (e) {
      _onFSException(e, linkUri, targetUri);
    }
  }

  // If this isn't working correctly, make sure the URI has been normalized first
  // with _fileUriNormalize
  FileSystemEntityType _fsTypeSync(Uri uri) {
    var type = FileStat.statSync(uri.toFilePath()).type;
    // Now manually check if it's a link
    if (FileSystemEntity.isLinkSync(uri.toFilePath())) {
      type = FileSystemEntityType.LINK;
    }

    return type;
  }

  void _onFSException(FileSystemException e, Uri link, Uri target) {
    if (e.osError.errorCode == 13) {
      print("Permission denied. Cannot link ${link.toFilePath()} to ${target.toFilePath()}");
    } else {
      throw e;
    }
  }
}
