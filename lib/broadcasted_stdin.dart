library broadcasted_stdin;

import 'dart:async';
import 'dart:io' as io;

class InteractiveProcess {

  final BroadcastedStdin stdin;

  List<String> arguments;
  String executable;
  String workingDirectory;
  Map<String, String> environment;

  /**
   * This is the same as Process.start except it runs interactively with the
   * user.
   */
  InteractiveProcess(this.stdin, this.executable,
                     this.arguments, {this.workingDirectory, this.environment});

  static Future<int> run(BroadcastedStdin stdin,
                         String executable, List<String> arguments,
                         {String workingDirectory,
                         Map<String, String> environment}) {
    return new InteractiveProcess(stdin, executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment).exec();
  }

  Future<int> exec() async {
    var process = await io.Process.start(executable, arguments,
                                         workingDirectory: workingDirectory,
                                         environment: environment);
    return _enableProcessInteraction(process);
  }

  Future<int> _enableProcessInteraction(io.Process process) {
    io.stdout.addStream(process.stdout);
    io.stderr.addStream(process.stderr);
    process.stdin.addStream(stdin.stream);
    return process.exitCode;
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
    }

    return _instance;
  }

  BroadcastedStdin._();

  /**
   * This will kill all instances of this listener. Call this when program
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
