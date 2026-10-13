import 'dart:convert';
import 'dart:io';

import 'package:koborin_ai_langfuse_infra/langfuse_stack.dart';
import 'package:terradart_core/terradart_core.dart';
import 'package:test/test.dart';

void main() {
  test('empty root keeps the R2 backend and both providers', () {
    final stack = LangfuseStack(
      projectId: 'n-koborinai',
      region: 'asia-northeast1',
      zone: 'asia-northeast1-b',
      backend: S3Backend.r2(
        accountId: 'acc-test',
        bucket: 'koborin-ai-tfstate',
        key: 'terraform/langfuse/terraform.tfstate',
      ),
    );
    final json = stack.synth().tfJson;

    expect(json.keys.toList(), ['terraform', 'provider']);
    expect(json.containsKey('resource'), isFalse);
    expect(json.containsKey('data'), isFalse);

    final terraform = json['terraform'] as Map<String, dynamic>;
    final backend = (terraform['backend'] as Map<String, dynamic>)['s3']
        as Map<String, dynamic>;
    expect(backend['bucket'], 'koborin-ai-tfstate');
    expect(backend['key'], 'terraform/langfuse/terraform.tfstate');

    final required = terraform['required_providers'] as Map<String, dynamic>;
    expect(required.keys.toList(), ['google', 'cloudflare']);

    expect(jsonEncode(json).contains('prevent_destroy'), isFalse);

    final google = (json['provider'] as Map<String, dynamic>)['google']
        as Map<String, dynamic>;
    expect(google['project'], 'n-koborinai');
    expect(google['region'], 'asia-northeast1');
    expect(google['zone'], 'asia-northeast1-b');
  });

  test('vm scripts are valid bash entry points', () {
    for (final path in ['vm/startup.sh', 'vm/shutdown.sh']) {
      expect(File(path).readAsLinesSync().first, '#!/usr/bin/env bash');
    }
  });
}
