import 'dart:io';

class SymbolicLink {
  final String linkName;
  final String target;

  SymbolicLink(String target, String linkName) :
      this.target = target,
      this.linkName = linkName;
  SymbolicLink.same(String link) :
      this(link, link);

  factory SymbolicLink.fromPrimitive(dynamic item) {
    if (item is Map) {
      if (item.keys.length > 1 || item.keys.isEmpty) {
        throw "Invalid number of keys for map $item";
      }

      var k = item.keys.first as String;
      return new SymbolicLink(k, item[k]);
    } else if (item is String) {
      return new SymbolicLink.same(item);
    }

    throw "Invalid link ${item}";
  }

  void link(String dotfilesPath, String installPath, dryRun,
            [user = '']) {
    var workingDir = new Directory('.').resolveSymbolicLinksSync();
    var targetUri = new Uri.file("$workingDir/${dotfilesPath}/${target}");
    targetUri = _fileUriNormalize(targetUri);
    var linkUri = new Uri.file("${installPath}/${linkName}");
    linkUri = _fileUriNormalize(linkUri);

    var link = new Link.fromUri(linkUri);
    var linkType = _fsTypeSync(linkUri);

    if (linkType != FileSystemEntityType.NOT_FOUND &&
        linkType != FileSystemEntityType.LINK || _isLinkValid(link)) {
      var currentTarget = new Uri.file(link.resolveSymbolicLinksSync());
      currentTarget = _fileUriNormalize(currentTarget);

      if (currentTarget != targetUri) {
        _backupTarget(currentTarget, targetUri, dryRun);
      } else {
        if (dryRun) print("Skipping ${link.path}. Already configured");
        return;
      }
    }

    if (FileStat.statSync(targetUri.toFilePath()).type ==
        FileSystemEntityType.NOT_FOUND && !dryRun) {
       print("Skipping ${link.path}. Link and target don't exist");
       return;
    }

    _forceCreateLink(link, linkUri, linkType, targetUri, dryRun);

    if (user.isNotEmpty) {
      Process.runSync('chown', ["$user:$user", "${link.path}"]);
    }
  }

  @override
  String toString() => "$linkName -> $target";

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
