import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'advanced_processing.dart';
import 'blissful_config.dart';

class Installer {
  BlissfulConfig configs;
  bool dryRun;
  List<String> configNames;

  HashSet _appsToInstall = new HashSet<AppBliss>();
  HashSet _envsToInstall = new HashSet<EnvBliss>();
  HashSet<RootBasicBliss> get _configsToInstall => _appsToInstall..addAll(_envsToInstall);
  HashSet<String> _debPkgsToInstall = new HashSet<String>();

  Installer(this.configNames, this.configs, this.dryRun) {
    if (configNames.isEmpty) throw "No apps or configs were specified";
    _initInstallLists();
  }

  Future install() async {
    try {
      if (!_isSuperUser() && !this.dryRun && _hasRootDependencies()) {
        await _obtainRoot();
      }

      if (_isSuperUser() || dryRun) {

        var user = _isSuperUser() ?
          Platform.environment['SUDO_USER'] : Platform.environment['USER'];
        await _rootInstall(user);
      }

      if (!_isSuperUser() || dryRun) {
        await _localInstall();
      }
    } finally {
      BroadcastedStdin.killAll();
    }
  }

  void _initInstallLists() {
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

  bool _isSuperUser() {
    return Platform.environment['USER'] == 'root';
  }

  Future _obtainRoot() async {
    var input = '';
    while (input != 'y' && input != 'n') {
      stdout.write("To continue, we need to run as root. Obtain root (y/n)? ");
      input = stdin.readLineSync().toLowerCase().trim();
    }

    if (input == 'y') {
      var args = ['dart', Platform.script.toFilePath()]..addAll(configNames);
      await InteractiveProcess.run(new BroadcastedStdin(), 'sudo', args);
    } else {
      print("No? Alright, skipping the root required stuff");
    }
  }

  bool _hasRootDependencies() {
    for (RootBasicBliss conf in _configsToInstall) {
      if (conf.rootBinaries.isNotEmpty) return true;
      if (conf.rootLinks.isNotEmpty) return true;
      if (conf.rootCopies.isNotEmpty) return true;
    }

    return _debPkgsToInstall.isNotEmpty;
  }

  Future _rootInstall(String user) async {
    print('***********************************');
    print('*** Running root install steps ****');
    print('');

    if (dryRun) print("Installing the following debian packages:");
    if (dryRun) print(_debPkgsToInstall.fold('', (v, pkg) => v + '    $pkg\n'));
    else {
      var stdin = new BroadcastedStdin();
      await InteractiveProcess.run(stdin, 'apt-get', ['update']);
      await InteractiveProcess.run(stdin, 'apt-get',
          ['install', '-y', '--allow-change-held-packages']..addAll(_debPkgsToInstall), runInShell: true);
    }
    print('Installation of debian packages complete\n');

    for (var conf in _configsToInstall) {
      conf.rootInstall(dryRun, user);
    }
  }

  Future _localInstall() async {
    print('\n*************************************');
    print('**** Running local install steps ****');
    print('');

    for (var conf in _configsToInstall) {
      await conf.localInstall(dryRun);
    }
  }
}
