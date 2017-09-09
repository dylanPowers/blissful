library broadcasted_stdin;

import 'dart:async';
import 'dart:io' as io;

class InteractiveProcess {

  final BroadcastedStdin stdin;

  List<String> arguments;
  String executable;
  String workingDirectory;
  Map<String, String> environment;
  bool runInShell = false;

  /**
   * This is the same as Process.start except it runs interactively with the
   * user.
   */
  InteractiveProcess(this.stdin, this.executable, this.arguments,
      {this.workingDirectory, this.environment, this.runInShell});

  static Future run(BroadcastedStdin stdin, String executable,
      List<String> arguments, {String workingDirectory,
        Map<String, String> environment, bool runInShell}) {
    return new InteractiveProcess(stdin, executable, arguments,
        workingDirectory: workingDirectory, environment: environment,
        runInShell: runInShell).exec();
  }

  Future exec() async {
    io.Process process = await io.Process.start(executable, arguments,
        workingDirectory: workingDirectory, environment: environment,
        runInShell: runInShell);
    var handle = _enableProcessInteraction(process);
    var exitCode = await process.exitCode;
		print("Trying to get the length");
		try {
			var length = await io.stdin.length.timeout(new Duration(seconds: 1));
			print("Is stdin empty? ${length}");
		} catch (e) {
			print("Nope, not happening");
		}
    await handle.timeout(Duration.ZERO);

		if (exitCode != 0) {
      throw "Failure running $executable $arguments\n"
          "Exit code: $exitCode";
    }
  }

  Future _enableProcessInteraction(io.Process process) {
    io.stdout.addStream(process.stdout);
    io.stderr.addStream(process.stderr);
    return process.stdin.addStream(stdin.stream);
  }
}

/**
 * A [BroadcastedStdin] allows for stdin to be listened to multiple times. This
 * solves the problem of wanting to pipe stdin to multiple processes.
 */
class BroadcastedStdin {
  Stream<List<int>> get stream => _stdin;

  static StreamSubscription _broadcastSubscript;
  static BroadcastedStdin _instance;
  Stream _stdin = io.stdin.asBroadcastStream(onListen: _onBroadcastListen);

  factory BroadcastedStdin() {
    if (_instance == null) {
      _instance = new BroadcastedStdin._();
			_instance._stdin.forEach((s) { print("DD: ${s}"); });
    }

    return _instance;
  }

  BroadcastedStdin._();

  /**
   * This will kill all instances of this listener. Call this when progrm
   * execution needs to finished. Failing to call this will result in a program
   * that will never end as it will be stuck waiting on user input.
   */
  static void killAll() {
    if (_broadcastSubscript != null) {
      _broadcastSubscript.cancel();
    }
  }

  static void _onBroadcastListen(StreamSubscription streamSubscript) {
    _broadcastSubscript = streamSubscript;
  }
}
