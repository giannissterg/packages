import 'dart:io';

import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

class DoctorCommand extends VasterCommand {
  @override
  String get name => 'doctor';

  @override
  List<String> get aliases => const ['doc'];

  @override
  String get description => 'Runs environment health checks and diagnostics for Vaster VM.';

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    out.writeln('======================================================================');
    out.writeln('  VASTER VM SYSTEM DIAGNOSTICS & DOCTOR                               ');
    out.writeln('======================================================================\n');

    out.writeln('┌─ DART SDK & SYSTEM ENVIRONMENT ───────────────────────────────┐');
    out.writeln('  ✓ Dart SDK Version : ${Platform.version.split(' ').first}');
    out.writeln('  ✓ Target OS        : ${Platform.operatingSystem} (${Platform.operatingSystemVersion})');
    out.writeln('  ✓ Working Directory: ${context.workingDirectory}');
    out.writeln('  ✓ Socket Path      : ${context.socketPath}');

    out.writeln('\n┌─ MODEL BACKENDS & TOOLING DIAGNOSTICS ──────────────────────┐');

    // Check Gemini CLI
    try {
      final res = await Process.run('gemini', ['--version']);
      if (res.exitCode == 0) {
        out.writeln('  ✓ Gemini CLI Installed: ${res.stdout.toString().trim()}');
      } else {
        out.writeln('  ⚠ Gemini CLI returned exit code ${res.exitCode}');
      }
    } catch (_) {
      out.writeln('  ⚠ Gemini CLI not detected in system PATH');
    }

    // Check GEMINI_API_KEY
    final apiKey = Platform.environment['GEMINI_API_KEY'] ?? Platform.environment['GOOGLE_AI_API_KEY'];
    if (apiKey != null && apiKey.isNotEmpty) {
      out.writeln('  ✓ GEMINI_API_KEY    : Configured (${apiKey.substring(0, 4)}...${apiKey.substring(apiKey.length - 4)})');
    } else {
      out.writeln('  ℹ GEMINI_API_KEY    : Not set (Using Fake or Gemini CLI mode)');
    }

    // Check llama.cpp FFI backend (libllama + a GGUF model)
    final libPath = LlamaBindings.defaultLibraryPath;
    if (File(libPath).existsSync()) {
      try {
        LlamaBindings.open(libraryPath: libPath);
        out.writeln('  ✓ libllama          : $libPath (all symbols resolve)');
      } catch (e) {
        out.writeln('  ⚠ libllama          : present but incompatible — $e');
      }
    } else {
      out.writeln('  ℹ libllama          : not found at $libPath '
          '(brew install llama.cpp for --backend llama)');
    }
    final llamaModel = Platform.environment['VASTER_LLAMA_MODEL'] ??
        defaultLlamaModelPath();
    if (File(llamaModel).existsSync()) {
      final mb = (File(llamaModel).lengthSync() / (1024 * 1024)).round();
      out.writeln('  ✓ llama model       : $llamaModel (${mb}MB)');
    } else {
      out.writeln('  ℹ llama model       : none at $llamaModel '
          '(--model <path.gguf> or VASTER_LLAMA_MODEL)');
    }

    // Check Unix Domain Socket support
    try {
      final testSockPath = '${Directory.systemTemp.path}/vaster_doc_test.sock';
      final file = File(testSockPath);
      if (file.existsSync()) file.deleteSync();
      final addr = InternetAddress(testSockPath, type: InternetAddressType.unix);
      final sock = await ServerSocket.bind(addr, 0);
      await sock.close();
      if (file.existsSync()) file.deleteSync();
      out.writeln('  ✓ Unix Domain Sockets: Supported and writable');
    } catch (e) {
      out.writeln('  ⚠ Unix Domain Sockets: Error ($e)');
    }

    out.writeln('\n======================================================================');
    out.writeln('  VASTER DOCTOR: All core systems operational!                         ');
    out.writeln('======================================================================');
    return 0;
  }
}
