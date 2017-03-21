#! /usr/bin/env dart

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:args/args.dart';
import 'package:yaml/yaml.dart';

import 'package:instant_bliss/advanced_processing.dart';

BroadcastedStdin stdin = new BroadcastedStdin();

Future main(List<String> argv) async {
  var parser = setupArgParser();

  Dotfiles dotfiles;
  try {
    var results = parser.parse(argv);
    var dotfiles = loadDotfiles();

    if (results['help']) {
      help(parser, dotfiles);
    } else {
      var install = new Installer(results.rest, dotfiles, results['dry-run']);
      await install.install();
    }
  } catch (e) {
    if (e.runtimeType == FormatException ||
        e.runtimeType == String) {
      if (e.runtimeType == FormatException) print('${e.message}\n');
      else print(e);

      print('idk what to do!\n');
      help(parser, dotfiles);
    } else rethrow;
  }

  BroadcastedStdin.killAll();
}

ArgParser setupArgParser() {
  var parser = new ArgParser();
  parser.addFlag('interactive', abbr: 'i', defaultsTo: false, negatable: false,
      help: 'Prompts to pick an environment before commencing a dry run and\n'
            'giving the option to continue');
  parser.addFlag('dry-run', defaultsTo: false, negatable: false,
      help: 'Verbose output without actually doing anything');
  parser.addFlag('update', abbr: 'u', defaultsTo: false, negatable: false,
      help: '(Experimental) Attempts to update/reinstall previously installed\n'
            'apps or envs');
  parser.addFlag('rm', defaultsTo: false, negatable: false,
      help: '(Experimental) Attempts to reverse a previous install');
  parser.addFlag('help', abbr: 'h', defaultsTo: false, negatable: false,
      help: 'This help message');
  return parser;
}

void help(ArgParser parser, [Dotfiles dotfiles]) {
  String availableApplications = "<None were loaded>";
  String availableEnvs = "<None were loaded>";

  if (dotfiles != null) {
    availableApplications = dotfiles.apps.values.fold('', (str, app) {
      return "$str    $app\n";
    });

    availableEnvs = dotfiles.envs.keys.fold('', (str, envname) {
      return "$str    $envname\n";
    });
  }

  print('''
Usage: instant-bliss [<options>] <apps or envs>

Be happy while using Linux!
Warning! When typing, rainbows may erupt from your fingertips.

Options:
${parser.usage}

Available apps:
$availableApplications
Available envs:
$availableEnvs''');
}

Dotfiles loadDotfiles() {
  String yaml;
  try {
    yaml = new File('dotfiles.yaml').readAsStringSync();
  } on FileSystemException catch(e) {
    throw e.message + " " + e.path;
  }
  var dotfilesRaw = loadYaml(yaml, sourceUrl: 'dotfiles.yaml');
  return new Dotfiles.fromMap(dotfilesRaw);
}

class Installer {
  Dotfiles configs;
  bool dryRun;

  HashSet _appsToInstall = new HashSet<AppConfig>();
  HashSet _envsToInstall = new HashSet<EnvConfig>();
  HashSet<String> _debPkgsToInstall = new HashSet<String>();

  Installer(List<String> configNames, this.configs, this.dryRun) {
    if (configNames.isEmpty) throw "No apps or configs were specified";
    _initInstallLists(configNames);
  }

  void _initInstallLists(List<String> configNames) {
    var namesCopy = new List.from(configNames);
    for (int i = 0; i < namesCopy.length; ++i) {
      var name = namesCopy[i];
      if (configs.containsApp(name)) {
        var app = configs.getAppByName(name);
        if (!_appsToInstall.contains(app)) {
          _appsToInstall.add(app);
          _debPkgsToInstall.addAll(app.debPkgs);
        }
      } else if (configs.envs.containsKey(name)) {
        var env = configs.envs[name];
        if (!_envsToInstall.contains(env)) {
          _envsToInstall.add(env);
          _debPkgsToInstall.addAll(env.debPkgs);
          namesCopy.addAll(env.deps);
        }
      } else {
        throw "Unknown app or env $name";
      }
    }
  }

  Future install() async {
    if (dryRun) print("Installing the following debian packages:");
    for (var pkg in _debPkgsToInstall) {
      if (dryRun) print('    $pkg');
    }
    print('Installation of debian packages complete\n');

    for (var app in _appsToInstall) {
      await app.install(dryRun);
    }

    for (var env in _envsToInstall) {
      env.install(dryRun);
    }
  }
}

class Dotfiles {
  Map<String, AppConfig> apps;
  Map<String, EnvConfig> envs;

  Dotfiles.fromMap(Map<String, dynamic> map) {
    for (String key in map.keys) {
      var val = map[key];
      switch (key) {
        case 'apps':
          apps = {};
          (val as Map).forEach((k,v) => apps[k] = new AppConfig.fromMap(k, v));
          break;
        case 'envs':
          envs = {};
          (val as Map).forEach((k,v) => envs[k] = new EnvConfig.fromMap(k, v));
          break;
      }
    }

    _testUnique();
  }

  bool containsApp(String name) {
    var split = name.split('=');
    return split.length <= 2 && apps.containsKey(split[0]);
  }

  AppConfig getAppByName(String name) {
    var split = name.split('=');
    var app = apps[split[0]];
    if (split.length > 1) app.version = split[1];
    return app;
  }

  void _testUnique() {
    for (var k in apps.keys) {
      if (envs.containsKey(k)) throw "App and env name $k is not unique";
    }
  }
}

class Config {
  String name = '';
  String info = '';

  List<SymbolicLink> binaries = [];
  List<SymbolicLink> rootBinaries = [];
  String dotfilesPath = _dotfilesPathDefault;
  String installPath = _installPathDefault;
  HashSet<String> _debPkgs = new HashSet<String>();
  HashSet<String> get debPkgs => _debPkgs;
  List<SymbolicLink> links = [];
  List<SymbolicLink> rootLinks = [];
  List<String> rootCopies = [];

  Config();

  Config.fromMap(this.name, Map<String, dynamic> map) {
    for (String key in map.keys) {
      var val = map[key];
      if (!_setVal(key, val)) {
        throw "Invalid key ${key} in ${this.name}";
      }
    }
  }

  bool _setVal(String k, dynamic v) {
    switch (k) {
      case 'info':
        info = v as String; break;
      case 'bin':
        binaries = (v as List).map((item) =>
            new SymbolicLink.fromPrimitive(item)); break;
      case 'root-bin':
        rootBinaries = (v as List).map((item) =>
            new SymbolicLink.fromPrimitive(item)); break;
      case 'dotfiles-path':
        dotfilesPath += '/' + (v as String);
        if (installPath == _installPathDefault) installPath += '/' + v;
        break;
      case 'install-path':
        installPath += '/' + (v as String); break;
      case 'deb-pkgs':
        _debPkgs.addAll(v as List<String>); break;
      case 'links':
        links = (v as List).map((item) =>
            new SymbolicLink.fromPrimitive(item)); break;
      case 'root-links':
        rootLinks = (v as List).map((item) =>
            new SymbolicLink.fromPrimitive(item)); break;
      case 'root-copies':
        rootCopies = (v as List<String>); break;
      default:
        return false;
    }

    return true;
  }

  void _setupLinks(String dotfilesPath, String installPath, bool dryRun) {
    links.forEach((ln) => ln.link(dotfilesPath, installPath, dryRun));
    rootLinks.forEach((ln) => ln.link('root', '/.', dryRun));
    binaries.forEach((ln) {
      ln.link('bin', Platform.environment['HOME'] + '/bin', dryRun);
    });
    rootBinaries.forEach((ln) => ln.link('bin', '/usr/local/bin', dryRun));
    print("Linking complete");
  }

  static String get _installPathDefault => Platform.environment['HOME'];
  static String get _dotfilesPathDefault => 'dotfiles';
}

class AppConfig extends Config {
  List<Version> versions = [];

  @override
  HashSet<String> get debPkgs => _flattenDebPkgs();

  Version _version;
  set version(String value)  {
    try {
      _version = versions.firstWhere((v) => v.name == value);
    } catch (StateError) {
      throw "The version string $value doesn't exist for the app $name";
    }
  }

  AppConfig.fromMap(String name, Map<String, dynamic> map) :
      super.fromMap(name, map) {
    if (versions.isNotEmpty) {
      _version = versions.last;
    }
  }

  Future install(bool dryRun) async {
    if (info.isNotEmpty) print(info);
    else print(name);

    var dotfilesPath = this.dotfilesPath;
    var installPath = this.installPath;
    if (versions.isNotEmpty) {
      dotfilesPath += '/' + _version.name;
      if (_version.installPath != Config._installPathDefault) {
         installPath = _version.installPath;
      }

      if (_version.dotfilesPath != Config._dotfilesPathDefault) {
       dotfilesPath = _version.dotfilesPath;
      }
    }

    _setupLinks(dotfilesPath, installPath, dryRun);
    if (_hasInstallScript()) {
      print("Running install script $_installScript");
      if (!dryRun) await _execInstallScript();
      print("Install script complete");
    }

    print('');
  }

  @override
  String toString() {
    if (versions.isNotEmpty) {
      var vers = versions.fold('',
              (str, v) => str == '' ? "[${v.name}" : "$str,${v.name}") + ']';
      return "$name=$vers";
    }

    return name;
  }

  String get _installScript => "install-scripts/$name.sh";

  Future _execInstallScript() async {
    var scriptFile = new File(_installScript);
    if (scriptFile.existsSync()) {
      var env = {};
      if (versions.isNotEmpty) env['VERSION'] = _version.name;
      var exitCode = await InteractiveProcess.run(stdin, scriptFile.path,
          [], environment: env);
      if (exitCode != 0) {
        print("Error code ${exitCode} ocurred running ${scriptFile.path}.");
      }
    }
  }

  HashSet<String> _flattenDebPkgs() {
    var flatDebPkgs = new HashSet<String>();
    flatDebPkgs.addAll(_debPkgs);
    if (versions.isNotEmpty) {
      flatDebPkgs.addAll(_version.debPkgs);
    }
    return flatDebPkgs;
  }

  bool _hasInstallScript() {
    var f = new File(_installScript);
    return f.existsSync();
  }

  @override
  bool _setVal(String k, dynamic v) {
    var result = super._setVal(k, v);
    if (!result) {
      switch (k) {
        case 'versions':
          versions = (v as List).map((item) =>
              new Version.fromPrimitive(item));
          return true;
        default:
          return false;
      }
    }

    return result;
  }
}

class EnvConfig extends Config {
  List<String> deps = [];

  EnvConfig.fromMap(String name, Map<String, dynamic> map) :
      super.fromMap(name, map);

  void install(bool dryRun) {
    if (info.isNotEmpty) print(info);
    else print(name);
    _setupLinks(this.dotfilesPath, this.installPath, dryRun);
    print('');
  }

  @override
  bool _setVal(String k, dynamic v) {
    var result = super._setVal(k, v);
    if (!result) {
      switch (k) {
        case 'deps':
          deps = v as List<String>;
          return true;
        default:
          return false;
      }
    }

    return result;
  }
}

class Version extends Config {

  Version.fromMap(String name, Map m) : super.fromMap(name, m);

  factory Version.fromPrimitive(dynamic item) {
    var v;
    if (item is String) {
      v = new Version.fromMap(item, {});
    } else if (item is Map) {
      var name = item.keys.first as String;
      v = new Version.fromMap(name, item[name]);
    } else {
      throw "Invalid version ${item}";
    }

    return v;
  }
}

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

    if (FileStat.statSync(targetUri.path).type ==
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
      if (dryRun) print("Copy ${currentTarget.path} to ${expectedTarget.path}");
      else _copy(currentTarget, expectedTarget);
    } else if (currentTargetType == FileSystemEntityType.DIRECTORY) {
      if (dryRun) print("Copy recursively ${currentTarget.path} to "
                        "${expectedTarget.path}");
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

    Process.runSync('cp', ['--recursive', '${fromUri.path}/.', '${toUri.path}']);
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

      if (dryRun) print("Link ${link.path} to ${targetUri.path}");
      else link.createSync(targetUri.path, recursive: true);
    } on FileSystemException catch (e) {
      _onFSException(e, linkUri, targetUri);
    }
  }

  FileSystemEntityType _fsTypeSync(Uri uri) {
    var type = FileStat.statSync(uri.path).type;
    // Now manually check if it's a link
    if (FileSystemEntity.isLinkSync(uri.path)) {
      type = FileSystemEntityType.LINK;
    }

    return type;
  }

  void _onFSException(FileSystemException e, Uri link, Uri target) {
    if (e.osError.errorCode == 13) {
      print("Permission denied. Cannot link ${link.path} to ${target.path}");
    } else {
      throw e;
    }
  }
}
