// Pass a canonical FLAC (48kHz, 16-bit, stereo) containing synthetic test audio.
// This developer-only diagnostic is never started by the product application.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:heming_audio/heming_audio.dart';

class _StreamStatistics {
  int samples = 0;
  int minimumBufferFrames = 48000 * 5;
  int maximumOutputUnderruns = 0;
  int maximumAbsolutePhaseErrorUs = 0;

  void observe(AudioStatus status) {
    if (status.state != AudioState.playing) return;
    samples++;
    if (status.bufferedFrames < minimumBufferFrames) {
      minimumBufferFrames = status.bufferedFrames;
    }
    if (status.outputUnderruns > maximumOutputUnderruns) {
      maximumOutputUnderruns = status.outputUnderruns;
    }
    if (status.phaseErrorMicros.abs() > maximumAbsolutePhaseErrorUs) {
      maximumAbsolutePhaseErrorUs = status.phaseErrorMicros.abs();
    }
  }

  Map<String, Object> toJson() => {
    'samples': samples,
    'minimumBufferFrames': samples == 0 ? 0 : minimumBufferFrames,
    'maximumOutputUnderruns': maximumOutputUnderruns,
    'maximumAbsolutePhaseErrorUs': maximumAbsolutePhaseErrorUs,
  };
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln(
      'Usage: dart run tools/lan_audio_host.dart SYNTHETIC_AUDIO_PATH [TIMEOUT_MINUTES]',
    );
    exitCode = 64;
    return;
  }
  final timeoutMinutes = args.length == 2 ? int.tryParse(args[1]) : 5;
  if (timeoutMinutes == null || timeoutMinutes < 1 || timeoutMinutes > 75) {
    stderr.writeln('TIMEOUT_MINUTES must be between 1 and 75.');
    exitCode = 64;
    return;
  }
  final engine = NativeAudioEngine();
  const session = 'heming-lan-diagnostic-session';
  const task = 'heming-lan-diagnostic-task';
  await engine.prepareLocal(path: args.first, sessionId: session, taskId: task);
  engine.setOutput(volume: 0, muted: true);
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 19846);
  stdout.writeln(
    'LAN_HOST_READY ${jsonEncode({'port': engine.audioPort, 'session': session, 'task': task})}',
  );
  final timeout = Timer(
    Duration(minutes: timeoutMinutes),
    () => server.close(force: true),
  );
  var statistics = _StreamStatistics();
  var failureLogged = false;
  Map<String, Object?> diagnosticStatus() {
    final status = engine.status;
    return {
      'state': status.state.name,
      'frames': status.playedFrames,
      'bufferFrames': status.bufferedFrames,
      'rttUs': status.clockRttMicros,
      'offsetUs': status.clockOffsetMicros,
      'hardwareClockValid': status.hardwareClockValid,
      'hardwareRatePpm': status.hardwareRatePpm,
      'phaseErrorUs': status.phaseErrorMicros,
      'driftPpm': status.driftPpm,
      'outputUnderruns': status.outputUnderruns,
      'outputSampleRate': status.outputSampleRate,
      'callbackFrames': status.callbackFrames,
      'error': status.error ?? '',
      'streamStatistics': statistics.toJson(),
    };
  }

  // Record the receiving Windows engine independently of the phone's HTTP
  // polling, so a depleted buffer remains visible in host failure output.
  final sampler = Timer.periodic(const Duration(milliseconds: 200), (_) {
    final status = engine.status;
    statistics.observe(status);
    if (status.state == AudioState.failed && !failureLogged) {
      failureLogged = true;
      stdout.writeln('LAN_HOST_FAILED ${jsonEncode(diagnosticStatus())}');
    }
  });
  try {
    await for (final request in server) {
      Map<String, Object?> result;
      try {
        switch (request.uri.path) {
          case '/config':
            result = {
              'port': engine.audioPort,
              'session': session,
              'task': task,
            };
          case '/start':
            statistics = _StreamStatistics();
            failureLogged = false;
            final start = NativeAudioEngine.monotonicMicros() + 1500000;
            engine.scheduleStart(start);
            result = {'startUs': start};
          case '/status':
            result = diagnosticStatus();
          case '/reverse':
            final peer = request.connectionInfo!.remoteAddress.address;
            final port = int.parse(request.uri.queryParameters['port']!);
            await engine.prepareRemote(
              host: peer,
              port: port,
              sessionId: 'heming-lan-reverse-session',
              taskId: 'heming-lan-reverse-task',
            );
            result = {'ready': true};
          case '/reverse_start':
            statistics = _StreamStatistics();
            failureLogged = false;
            engine.scheduleStart(
              int.parse(request.uri.queryParameters['startUs']!),
            );
            result = {'scheduled': true};
          case '/reset':
            await engine.stop();
            result = {'stopped': true};
          case '/stop':
            stdout.writeln('LAN_HOST_RESULT ${jsonEncode(diagnosticStatus())}');
            await engine.stop();
            result = {'stopped': true};
          default:
            request.response.statusCode = 404;
            result = {'error': 'unknown diagnostic route'};
        }
      } catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        result = {'error': error.toString(), 'status': diagnosticStatus()};
        stdout.writeln('LAN_HOST_REQUEST_FAILED ${jsonEncode(result)}');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
      if (request.uri.path == '/stop') {
        unawaited(server.close());
      }
    }
  } finally {
    sampler.cancel();
    timeout.cancel();
    await engine.dispose();
  }
}
