/// Synth entry point for langfuse.koborin.ai infrastructure.
///
/// Run `dart run bin/synth.dart` to emit `tf-out/langfuse/main.tf.json`.
///
/// Set `CLOUDFLARE_ACCOUNT_ID`. Apply-time inputs (`CLOUDFLARE_API_TOKEN`,
/// Google ADC from Workload Identity Federation, the R2 keys the backend
/// reads through `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, and the
/// sensitive `TF_VAR_owner_email`) never reach synth.
library;

import 'dart:io';

import 'package:koborin_ai_langfuse_infra/langfuse_stack.dart';
import 'package:terradart_core/terradart_core.dart';

const _outputDir = 'tf-out/langfuse';
const _stateBucket = 'koborin-ai-tfstate';
const _stateKey = 'terraform/langfuse/terraform.tfstate';

Future<void> main() async {
  final accountId = Platform.environment['CLOUDFLARE_ACCOUNT_ID']!;

  final stack = LangfuseStack(
    projectId: 'n-koborinai',
    region: 'asia-northeast1',
    zone: 'asia-northeast1-b',
    machineType: 't2d-standard-4',
    spot: true,
    cloudflareAccountId: accountId,
    zoneName: 'koborin.ai',
    hostname: 'langfuse.koborin.ai',
    gateUiWithAccess: true,
    startupScript: File('vm/startup.sh').readAsStringSync(),
    shutdownScript: File('vm/shutdown.sh').readAsStringSync(),
    backend: S3Backend.r2(
      accountId: accountId,
      bucket: _stateBucket,
      key: _stateKey,
    ),
  );

  await stack.writeTo(_outputDir);
  stdout.writeln('synthesized stack to $_outputDir/main.tf.json');
}
