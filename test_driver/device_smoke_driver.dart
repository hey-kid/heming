import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: Duration(
    seconds:
        int.tryParse(
          Platform.environment['HEMING_TEST_TIMEOUT_SECONDS'] ?? '',
        ) ??
        2400,
  ),
  writeResponseOnFailure: true,
);
