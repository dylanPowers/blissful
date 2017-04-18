import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:yaml/yaml.dart';

import 'advanced_processing.dart';
import 'symbolic_link.dart';

class BlissfulConfig {
  Map<String, AppBliss> apps;
  Map<String, EnvBliss> envs;

  factory BlissfulConfig.fromYaml(String filename) {
    String yaml;
    try {
      yaml = new File(filename).readAsStringSync();
    } on FileSystemException catch(e) {
      throw e.message + " " + e.path;
    }
    var dotfilesRaw = loadYaml(yaml, sourceUrl: filename);
    return new BlissfulConfig.fromMap(dotfilesRaw);
  }

  BlissfulConfig.fromMap(Map<String, dynamic> map) {
    for (String key in map.keys) {
      var val = map[key];
      switch (key) {
        case 'apps':
          apps = {};
          (val as Map).forEach((k,v) => apps[k] = new AppBliss.fromMap(k, v));
          break;
        case 'envs':
          envs = {};
          (val as Map).forEach((k,v) => envs[k] = new EnvBliss.fromMap(k, v));
          break;
      }
    }

    _testUnique();
  }

  bool containsApp(String name) {
    var split = name.split('=');
    return split.length <= 2 && apps.containsKey(split[0]);
  }

  AppBliss getAppByName(String name) {
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

class BasicBliss {
  String name = '';

  List<SymbolicLink> binaries = [];
  List<SymbolicLink> rootBinaries = [];
  String dotfilesPath = _dotfilesPathDefault;
  String installPath = _installPathDefault;
  HashSet<String> _debPkgs = new HashSet<String>();
  HashSet<String> get debPkgs => _debPkgs;

  BasicBliss();

  BasicBliss.fromMap(this.name, Map<String, dynamic> map) {
    for (String key in map.keys) {
      var val = map[key];
      if (!_setVal(key, val)) {
        throw "Invalid key ${key} in ${this.name}";
      }
    }
  }

  bool _setVal(String k, dynamic v) {
    switch (k) {
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
      default:
        return false;
    }

    return true;
  }

  static String get _installPathDefault => Platform.environment['HOME'];
  static String get _dotfilesPathDefault => 'dotfiles';
}

class RootBasicBliss extends BasicBliss {
  String info = '';
  List<SymbolicLink> links = [];
  List<SymbolicLink> rootLinks = [];
  List<String> rootCopies = [];

  RootBasicBliss.fromMap(String name, Map<String, dynamic> map) : super.fromMap(name, map);

  @override
  bool _setVal(String k, dynamic v) {
    var result = super._setVal(k, v);
    if (!result) {
      switch (k) {
        case 'info':
          info = v as String; break;
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

      result = true;
    }

    return result;
  }

  void _printName() {
    if (info.isNotEmpty) print(info);
    else print(name);
  }

  void _setupLinks(String dotfilesPath, String installPath, bool dryRun) {
    links.forEach((ln) => ln.link(dotfilesPath, installPath, dryRun));
    binaries.forEach((ln) {
      ln.link('bin', Platform.environment['HOME'] + '/bin', dryRun);
    });
    print("Linking complete");
  }

  void _setupRootLinks(bool dryRun) {
    rootLinks.forEach((ln) => ln.link('root', '/.', dryRun));
    rootBinaries.forEach((ln) => ln.link('bin', '/usr/local/bin', dryRun));
    print("Linking complete");
  }

  Future localInstall(bool dryRun) async {
    _preLocalInstall();
    _setupLinks(dotfilesPath, installPath, dryRun);
    await _postLocalInstall(dryRun);
  }

  void _preLocalInstall() {
    _printName();
  }

  Future _postLocalInstall(bool dryRun) async {
    print('');
  }

  void rootInstall(bool dryRun) {
    _printName();
    _setupRootLinks(dryRun);
    print('');
  }
}

class AppBliss extends RootBasicBliss {
  List<VersionBliss> versions = [];

  @override
  HashSet<String> get debPkgs => _flattenDebPkgs();

  VersionBliss _version;
  set version(String value)  {
    try {
      _version = versions.firstWhere((v) => v.name == value);
    } catch (StateError) {
      throw "The version string $value doesn't exist for the app $name";
    }
  }

  AppBliss.fromMap(String name, Map<String, dynamic> map) :
      super.fromMap(name, map) {
    if (versions.isNotEmpty) {
      _version = versions.last;
      dotfilesPath += '/' + _version.name;
      if (_version.installPath != BasicBliss._installPathDefault) {
         installPath = _version.installPath;
      }

      if (_version.dotfilesPath != BasicBliss._dotfilesPathDefault) {
       dotfilesPath = _version.dotfilesPath;
      }
    }
  }

  @override
  bool _setVal(String k, dynamic v) {
    var result = super._setVal(k, v);
    if (!result) {
      switch (k) {
        case 'versions':
          versions = (v as List).map((item) =>
              new VersionBliss.fromPrimitive(item));
          return true;
        default:
          return false;
      }
    }

    return result;
  }

  @override
  Future _postLocalInstall(bool dryRun) async {
    if (_hasInstallScript()) {
      print("Running install script $_installScript");
      if (!dryRun) await _execInstallScript();
      print("Install script complete");
    }

    super._postLocalInstall(dryRun);
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
      var env = {}..addAll(Platform.environment);
      if (versions.isNotEmpty) env['VERSION'] = _version.name;
      await InteractiveProcess.run(new BroadcastedStdin(),
          scriptFile.path, [], environment: env);
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
}

class EnvBliss extends RootBasicBliss {
  List<String> deps = [];

  EnvBliss.fromMap(String name, Map<String, dynamic> map) :
      super.fromMap(name, map);

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

class VersionBliss extends BasicBliss {

  VersionBliss.fromMap(String name, Map m) : super.fromMap(name, m);

  factory VersionBliss.fromPrimitive(dynamic item) {
    var v;
    if (item is String) {
      v = new VersionBliss.fromMap(item, {});
    } else if (item is Map) {
      var name = item.keys.first as String;
      v = new VersionBliss.fromMap(name, item[name]);
    } else {
      throw "Invalid version ${item}";
    }

    return v;
  }
}
