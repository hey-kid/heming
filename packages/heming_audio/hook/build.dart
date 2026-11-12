import 'dart:convert';
import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final os = input.config.code.targetOS;
    if (os == OS.windows && input.config.code.cCompiler == null) {
      // Native-toolchain's vswhere JSON reader is affected by localized VS
      // descriptions on some Windows installations. Query only ASCII paths.
      final vswhere =
          '${Platform.environment['ProgramFiles(x86)'] ?? Platform.environment['PROGRAMFILES(X86)'] ?? r'C:\Program Files (x86)'}\\Microsoft Visual Studio\\Installer\\vswhere.exe';
      Future<String> property(String name) async {
        final result = await Process.run(vswhere, [
          '-latest',
          '-products',
          '*',
          '-property',
          name,
        ], stdoutEncoding: utf8);
        if (result.exitCode != 0 || (result.stdout as String).trim().isEmpty) {
          throw StateError(
            'Visual Studio with Desktop C++ workload is required.',
          );
        }
        return (result.stdout as String).trim();
      }

      final installation = await property('installationPath');
      final major = int.parse(
        (await property('installationVersion')).split('.').first,
      );
      final cmake =
          '$installation\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe';
      final buildDir = input.outputDirectory.resolve('cmake/').toFilePath();
      final arch = input.config.code.targetArchitecture;
      final platform = arch == Architecture.arm64
          ? 'ARM64'
          : arch == Architecture.ia32
          ? 'Win32'
          : 'x64';
      final generator = major >= 18
          ? 'Visual Studio 18 2026'
          : major == 17
          ? 'Visual Studio 17 2022'
          : 'Visual Studio 16 2019';
      for (final arguments in [
        [
          '-S',
          input.packageRoot.toFilePath(),
          '-B',
          buildDir,
          '-G',
          generator,
          '-A',
          platform,
        ],
        ['--build', buildDir, '--config', 'Release'],
      ]) {
        final result = await Process.run(cmake, arguments);
        if (result.exitCode != 0) {
          throw StateError('CMake failed: ${result.stdout}\n${result.stderr}');
        }
      }
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'heming_audio_bindings.dart',
          linkMode: DynamicLoadingBundled(),
          file: Directory(buildDir).uri.resolve('Release/heming_audio.dll'),
        ),
      );
      output.dependencies.add(input.packageRoot.resolve('CMakeLists.txt'));
      await for (final file in Directory.fromUri(
        input.packageRoot.resolve('src/'),
      ).list(recursive: true)) {
        if (file is File) output.dependencies.add(file.uri);
      }
      return;
    }
    await CBuilder.library(
      name: 'heming_audio',
      assetName: 'heming_audio_bindings.dart',
      sources: ['src/heming_audio.cpp', 'src/preview_player.cpp'],
      includes: ['src'],
      language: Language.cpp,
      std: 'c++17',
      cppLinkStdLib: os == OS.android ? 'c++_static' : null,
      flags: os == OS.windows ? ['/utf-8', '/EHsc'] : [],
      libraries: os == OS.windows
          ? ['ws2_32', 'ole32', 'avrt']
          : ['dl', 'm', 'log', 'atomic', 'aaudio'],
    ).run(input: input, output: output);
  });
}
