import 'dart:io';

import 'package:koborin_ai_langfuse_infra/langfuse_stack.dart';
import 'package:test/test.dart';

Map<String, dynamic> _synth({bool spot = true, bool gate = true}) {
  final stack = LangfuseStack(
    projectId: 'proj-test',
    region: 'asia-northeast1',
    zone: 'asia-northeast1-b',
    machineType: 't2d-standard-4',
    spot: spot,
    cloudflareAccountId: 'acc-test',
    zoneName: 'koborin.ai',
    hostname: 'langfuse.koborin.ai',
    gateUiWithAccess: gate,
    startupScript: '#!/bin/bash\necho start "\${HOME}"',
    shutdownScript: '#!/bin/bash\necho stop',
  );
  return stack.synth().tfJson;
}

Map<String, dynamic> _resource(
  Map<String, dynamic> json,
  String type,
  String name,
) =>
    ((json['resource'] as Map)[type] as Map)[name] as Map<String, dynamic>;

void main() {
  test('VM is a Spot t2d with no external IP and the data disk attached', () {
    final vm = _resource(_synth(), 'google_compute_instance', 'langfuse');

    expect(vm['machine_type'], 't2d-standard-4');
    expect(vm['zone'], 'asia-northeast1-b');

    final nic = (vm['network_interface'] as List).single as Map;
    expect(nic.containsKey('access_config'), isFalse);

    final scheduling = (vm['scheduling'] as List).single as Map;
    expect(scheduling['provisioning_model'], 'SPOT');
    expect(scheduling['instance_termination_action'], 'STOP');
    expect(scheduling['automatic_restart'], false);

    final disk = (vm['attached_disk'] as List).single as Map;
    expect(disk['device_name'], 'langfuse-data');
    expect(disk['source'], r'${google_compute_disk.data.self_link}');

    final metadata = vm['metadata'] as Map;
    expect(metadata['enable-oslogin'], 'TRUE');
    expect(metadata['startup-script'], contains(r'echo start "$${HOME}"'));
    expect(metadata['shutdown-script'], contains('echo stop'));
  });

  test('spot: false switches to an on-demand VM that live-migrates', () {
    final vm = _resource(
      _synth(spot: false),
      'google_compute_instance',
      'langfuse',
    );
    final scheduling = (vm['scheduling'] as List).single as Map;
    expect(scheduling['provisioning_model'], 'STANDARD');
    expect(scheduling['on_host_maintenance'], 'MIGRATE');
    expect(scheduling.containsKey('instance_termination_action'), isFalse);
  });

  test('data disk is protected and snapshotted daily for 7 days', () {
    final json = _synth();
    final disk = _resource(json, 'google_compute_disk', 'data');
    expect(disk['size'], 100);
    expect((disk['lifecycle'] as Map)['prevent_destroy'], true);

    final policy = _resource(
      json,
      'google_compute_resource_policy',
      'daily_snapshot',
    );
    final schedule = policy['snapshot_schedule_policy'] as Map;
    final retention = schedule['retention_policy'] as Map;
    expect(retention['max_retention_days'], 7);
  });

  test('only IAP may reach port 22', () {
    final fw = _resource(_synth(), 'google_compute_firewall', 'iap_ssh');
    expect(fw['source_ranges'], ['35.235.240.0/20']);
    expect(fw['allow'], [
      {
        'protocol': 'tcp',
        'ports': ['22'],
      },
    ]);
  });

  test('Cloud Scheduler starts the VM every 5 minutes', () {
    final job = _resource(_synth(), 'google_cloud_scheduler_job', 'start_vm');
    expect(job['schedule'], '*/5 * * * *');
    final target = job['http_target'] as Map;
    expect(target['http_method'], 'POST');
    expect(
      target['uri'],
      'https://compute.googleapis.com/compute/v1/projects/proj-test'
      '/zones/asia-northeast1-b/instances/langfuse/start',
    );
  });

  test('tunnel token lands in Secret Manager as write-only data', () {
    final version = _resource(
      _synth(),
      'google_secret_manager_secret_version',
      'cloudflared_token',
    );
    expect(
      version['secret_data_wo'],
      r'${data.cloudflare_zero_trust_tunnel_cloudflared_token.langfuse.token}',
    );
    expect(version.containsKey('secret_data'), isFalse);
  });

  test('DNS points at the tunnel through the Cloudflare proxy', () {
    final json = _synth();
    final record = _resource(json, 'cloudflare_dns_record', 'langfuse');
    expect(record['type'], 'CNAME');
    expect(record['proxied'], true);
    expect(
      record['content'],
      r'${cloudflare_zero_trust_tunnel_cloudflared.langfuse.id}.cfargotunnel.com',
    );

    final config = _resource(
      json,
      'cloudflare_zero_trust_tunnel_cloudflared_config',
      'langfuse',
    );
    final ingress = (config['config'] as Map)['ingress'] as List;
    expect((ingress.first as Map)['service'], 'http://langfuse-web:3000');
    expect((ingress.last as Map)['service'], 'http_status:404');
  });

  test('Access gates the UI but bypasses /api/public', () {
    final json = _synth();
    final ui = _resource(json, 'cloudflare_zero_trust_access_application', 'ui');
    final api = _resource(
      json,
      'cloudflare_zero_trust_access_application',
      'public_api',
    );
    expect(ui['domain'], 'langfuse.koborin.ai');
    expect(api['domain'], 'langfuse.koborin.ai/api/public');

    final bypass = _resource(
      json,
      'cloudflare_zero_trust_access_policy',
      'public_api_bypass',
    );
    expect(bypass['decision'], 'bypass');
  });

  test('gateUiWithAccess: false removes every Access resource', () {
    final resources = _synth(gate: false)['resource'] as Map;
    expect(
      resources.keys.where((k) => (k as String).contains('access')),
      isEmpty,
    );
  });

  test('R2 blob bucket allows browser uploads from the Langfuse origin', () {
    final cors = _resource(_synth(), 'cloudflare_r2_bucket_cors', 'blob');
    final rule = (cors['rules'] as List).single as Map;
    expect((rule['allowed'] as Map)['origins'], ['https://langfuse.koborin.ai']);
  });

  test('owner email is a sensitive variable, never a literal', () {
    final json = _synth();
    final variable = (json['variable'] as Map)['owner_email'] as Map;
    expect(variable['sensitive'], true);

    final policy = _resource(
      json,
      'cloudflare_zero_trust_access_policy',
      'owner_only',
    );
    final include = (policy['include'] as List).single as Map;
    expect((include['email'] as Map)['email'], r'${var.owner_email}');

    final channel = _resource(
      json,
      'google_monitoring_notification_channel',
      'owner_email',
    );
    expect(channel['labels'], {'email_address': r'${var.owner_email}'});
  });

  test('vm scripts are valid bash entry points', () {
    for (final path in ['vm/startup.sh', 'vm/shutdown.sh']) {
      expect(File(path).readAsLinesSync().first, '#!/usr/bin/env bash');
    }
  });
}
