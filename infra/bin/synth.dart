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
    backend: S3Backend.r2(
      accountId: accountId,
      bucket: _stateBucket,
      key: _stateKey,
    ),
  );

  await stack.writeTo(_outputDir);
  stdout.writeln('synthesized stack to $_outputDir/main.tf.json');
}
