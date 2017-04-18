#! /usr/bin/env dart

import 'dart:async';
import 'package:args/args.dart';

import 'package:blissful/blissful.dart';


Future main(List<String> argv) async {
  var parser = setupArgParser();

  BlissfulConfig dotfiles;
  try {
    var results = parser.parse(argv);
    dotfiles = new BlissfulConfig.fromYaml('blissful.yaml');

    if (results['help']) {
      help(parser, dotfiles);
    } else {
      var installer = new Installer(results.rest, dotfiles, results['dry-run']);
      await installer.install();
    }
  } catch (e) {
    if (e.runtimeType == FormatException ||
      e.runtimeType == String) {
      if (e.runtimeType == FormatException) print('${e.message}\n');
      else print(e);

      print('\nidk what to do!\n');
      help(parser, dotfiles);
    } else rethrow;
  }
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

void help(ArgParser parser, [BlissfulConfig dotfiles]) {
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
Usage: blissful [<options>] <apps or envs>

Make using Linux a blissful experience!
Warning! When typing, rainbows may erupt from your fingertips.

Options:
${parser.usage}

Available apps:
$availableApplications
Available envs:
$availableEnvs''');
}





