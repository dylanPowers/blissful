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

  StreamSubscription<List<int>> _stdinHandle;

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
    _enableProcessInteraction(process);
    var exitCode = await process.exitCode;
    await _stdinHandle.cancel();

    if (exitCode != 0) {
      throw "Failure running $executable $arguments\n"
          "Exit code: $exitCode";
    }
  }

  void _enableProcessInteraction(io.Process process) {
    io.stdout.addStream(process.stdout);
    io.stderr.addStream(process.stderr);
    _stdinHandle = stdin.pipe(process.stdin);
  }
}

/**
 * A [BroadcastedStdin] allows for stdin to be listened to multiple times. This
 * solves the problem of wanting to pipe stdin to multiple processes.
 */
class BroadcastedStdin {
  static StreamSubscription _broadcastSubscript;
  static BroadcastedStdin _instance;
  Stream _stdin = io.stdin.asBroadcastStream(onListen: _onBroadcastListen,
      onCancel: _onBroadcastListenCancel);

  factory BroadcastedStdin() {
    if (_instance == null) {
      _instance = new BroadcastedStdin._();
    }

    return _instance;
  }

  BroadcastedStdin._();

  StreamSubscription<List<int>> pipe(StreamConsumer consumer) {
    _stdin.pipe(consumer);
    return _broadcastSubscript;
  }

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

  static void _onBroadcastListenCancel(StreamSubscription streamSubscript) {
    // "If...[the broadcast stream]...later gets a new listener,
    // the [onListen] function is called again."
    // I've actually found this to not be true, or else we'd have the following
    // _broadcastSubscript = null;
  }
}
