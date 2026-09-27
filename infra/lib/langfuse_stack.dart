import 'package:terradart_cloudflare/data.dart';
import 'package:terradart_cloudflare/dns.dart';
import 'package:terradart_cloudflare/provider.dart';
import 'package:terradart_cloudflare/r2.dart';
import 'package:terradart_cloudflare/zero_trust.dart';
import 'package:terradart_core/terradart_core.dart';
import 'package:terradart_google/cloud_scheduler.dart';
import 'package:terradart_google/compute.dart';
import 'package:terradart_google/iam.dart';
import 'package:terradart_google/monitoring.dart';
import 'package:terradart_google/project.dart';
import 'package:terradart_google/provider.dart';
import 'package:terradart_google/secret_manager.dart';

/// Self-hosted Langfuse on one GCE Spot VM running Docker Compose, reached
/// only through a Cloudflare Tunnel.
///
/// GCP: a private VPC with Cloud NAT, the VM with a separate data disk and
/// daily snapshots, a Cloud Scheduler job that restarts the VM after Spot
/// preemption, Secret Manager slots for the app `.env` and tunnel token,
/// and uptime / disk / memory alerts.
///
/// Cloudflare: the tunnel and its ingress, the proxied CNAME, R2 buckets for
/// Langfuse blobs and nightly backups, and (while [gateUiWithAccess] is set)
/// Access apps that keep the UI private but leave `/api/public/*` open for
/// SDK / OTel ingestion.
///
/// The Compose project itself is not managed here; `deploy-app.yml` ships
/// `deploy/` to the VM over IAP.
final class LangfuseStack extends Stack {
  LangfuseStack({
    required String projectId,
    required String region,
    required String zone,
    required String machineType,
    required bool spot,
    required String cloudflareAccountId,
    required String zoneName,
    required String hostname,
    required bool gateUiWithAccess,
    required String startupScript,
    required String shutdownScript,
    super.backend,
  }) : super(
          providers: [
            GoogleProvider(project: projectId, region: region, zone: zone),
            const CloudflareProvider(),
          ],
        ) {
    final project = TfArg.literal(projectId);
    final cfAccount = TfArg.literal(cloudflareAccountId);
    const labels = {'app': 'langfuse', 'managed-by': 'terradart'};

    // The repository is public, so the owner's address never appears in
    // synth output or plan logs; CI passes it as TF_VAR_owner_email.
    addVariable(
      'owner_email',
      const TfVariable(
        type: 'string',
        sensitive: true,
        description: 'Address Cloudflare Access admits and alerts go to.',
      ),
    );
    final ownerEmail = TfArg.variable<String>('owner_email');

    // --- Project APIs -----------------------------------------------------
    // The bootstrap script enables these too, so the first apply never waits
    // on them; declaring them here keeps the dependency list reviewable.
    for (final api in const [
      'compute',
      'iap',
      'oslogin',
      'secretmanager',
      'cloudscheduler',
      'monitoring',
      'logging',
    ]) {
      add(
        GoogleProjectService(
          localName: api,
          project: project,
          service: TfArg.literal('$api.googleapis.com'),
          disableOnDestroy: TfArg.literal(false),
        ),
      );
    }

    // --- Network: no public IPs; egress via Cloud NAT, SSH via IAP only ---
    final network = add(
      GoogleComputeNetwork(
        localName: 'langfuse',
        name: TfArg.literal('langfuse'),
        autoCreateSubnetworks: TfArg.literal(false),
        project: project,
      ),
    );

    final subnet = add(
      GoogleComputeSubnetwork(
        localName: 'langfuse',
        name: TfArg.literal('langfuse-$region'),
        region: TfArg.literal(region),
        network: TfArg.ref(network.id),
        ipCidrRange: TfArg.literal('10.10.0.0/24'),
        privateIpGoogleAccess: TfArg.literal(true),
        project: project,
      ),
    );

    final router = add(
      GoogleComputeRouter(
        localName: 'langfuse',
        name: TfArg.literal('langfuse'),
        region: TfArg.literal(region),
        network: TfArg.ref(network.id),
        project: project,
      ),
    );

    add(
      GoogleComputeRouterNat(
        localName: 'langfuse',
        name: TfArg.literal('langfuse'),
        router: TfArg.ref(router.nameRef),
        region: TfArg.literal(region),
        natIpAllocateOption: TfArg.literal(
          ComputeRouterNatNatIpAllocateOption.autoOnly,
        ),
        sourceSubnetworkIpRangesToNat: TfArg.literal(
          ComputeRouterNatSourceSubnetworkIpRangesToNat
              .allSubnetworksAllIpRanges,
        ),
        project: project,
      ),
    );

    // 35.235.240.0/20 is the fixed source range of IAP TCP forwarding.
    // Every other ingress falls through to the VPC's implied deny.
    add(
      GoogleComputeFirewall(
        localName: 'iap_ssh',
        name: TfArg.literal('langfuse-allow-iap-ssh'),
        network: TfArg.ref(network.id),
        direction: TfArg.literal(FirewallDirection.ingress),
        rulePolicy: ComputeFirewallAllowPolicy(
          protocol: TfArg.literal('tcp'),
          ports: const ['22'],
        ),
        sourceRanges: TfArg.literal(const ['35.235.240.0/20']),
        targetTags: TfArg.literal(const ['langfuse']),
        project: project,
      ),
    );

    // --- VM identity ------------------------------------------------------
    final vmSa = add(
      GoogleServiceAccount(
        localName: 'vm',
        accountId: TfArg.literal('langfuse-vm'),
        displayName: TfArg.literal('Langfuse VM'),
        project: project,
      ),
    );

    for (final (name, role) in const [
      ('vm_log_writer', 'roles/logging.logWriter'),
      ('vm_metric_writer', 'roles/monitoring.metricWriter'),
    ]) {
      add(
        GoogleProjectIamMember(
          localName: name,
          project: project,
          role: TfArg.literal(role),
          member: TfArg.ref(vmSa.iamMember),
        ),
      );
    }

    // --- Secrets ----------------------------------------------------------
    // `langfuse-env` holds the app `.env`. Its versions are added by hand
    // (`gcloud secrets versions add`), so no plaintext reaches state.
    final envSecret = add(
      GoogleSecretManagerSecret(
        localName: 'langfuse_env',
        secretId: TfArg.literal('langfuse-env'),
        replication: const SecretManagerSecretAutoReplication(),
        labels: TfArg.literal(labels),
        project: project,
      ),
    );

    final tunnelSecret = add(
      GoogleSecretManagerSecret(
        localName: 'cloudflared_token',
        secretId: TfArg.literal('cloudflared-token'),
        replication: const SecretManagerSecretAutoReplication(),
        labels: TfArg.literal(labels),
        project: project,
      ),
    );

    for (final (name, secret) in [
      ('vm_reads_env', envSecret),
      ('vm_reads_tunnel_token', tunnelSecret),
    ]) {
      add(
        GoogleSecretManagerSecretIamMember(
          localName: name,
          secretId: TfArg.ref(secret.id),
          role: TfArg.literal('roles/secretmanager.secretAccessor'),
          member: TfArg.ref(vmSa.iamMember),
          project: project,
        ),
      );
    }

    // --- Disks and snapshots ----------------------------------------------
    // Postgres, ClickHouse, Redis, and the deployed Compose files live here,
    // so the VM can be recreated (e.g. a new Ubuntu image) without data loss.
    final dataDisk = add(
      GoogleComputeDisk(
        localName: 'data',
        name: TfArg.literal('langfuse-data'),
        zone: TfArg.literal(zone),
        type: TfArg.literal('pd-balanced'),
        size: TfArg.literal(100),
        labels: TfArg.literal(labels),
        project: project,
        lifecycle: const LifecycleOptions(preventDestroy: true),
      ),
    );

    final snapshots = add(
      GoogleComputeResourcePolicy(
        localName: 'daily_snapshot',
        name: TfArg.literal('langfuse-data-daily'),
        region: TfArg.literal(region),
        snapshotSchedulePolicy: ComputeResourcePolicySnapshotSchedulePolicy(
          // 18:00 UTC is 03:00 JST.
          schedule: ComputeResourcePolicyDailySchedule(
            daysInCycle: TfArg.literal(1),
            startTime: TfArg.literal('18:00'),
          ),
          retentionPolicy: ComputeResourcePolicyRetentionPolicy(
            maxRetentionDays: TfArg.literal(7),
            onSourceDiskDelete: TfArg.literal(
              ComputeResourcePolicyOnSourceDiskDelete.keepAutoSnapshots,
            ),
          ),
          snapshotProperties: ComputeResourcePolicySnapshotProperties(
            labels: TfArg.literal(labels),
            storageLocations: TfArg.literal([region]),
          ),
        ),
        project: project,
      ),
    );

    add(
      GoogleComputeDiskResourcePolicyAttachment(
        localName: 'data_daily_snapshot',
        name: TfArg.ref(snapshots.nameRef),
        disk: TfArg.ref(dataDisk.nameRef),
        zone: TfArg.literal(zone),
        project: project,
      ),
    );

    // --- VM ---------------------------------------------------------------
    final vm = add(
      GoogleComputeInstance(
        localName: 'langfuse',
        name: TfArg.literal('langfuse'),
        machineType: TfArg.literal(machineType),
        zone: TfArg.literal(zone),
        tags: TfArg.literal(const ['langfuse']),
        labels: TfArg.literal(labels),
        allowStoppingForUpdate: TfArg.literal(true),
        bootDisk: ComputeInstanceBootDisk(
          initializeParams: ComputeInstanceInitializeParams(
            // An image family: the provider resolves it at create time and
            // does not plan a replacement when the family moves forward.
            image: TfArg.literal('ubuntu-os-cloud/ubuntu-2404-lts-amd64'),
            size: TfArg.literal(20),
            type: TfArg.literal('pd-balanced'),
          ),
        ),
        attachedDisk: [
          ComputeInstanceAttachedDisk(
            source: TfArg.ref(dataDisk.selfLink),
            // Shows up as /dev/disk/by-id/google-langfuse-data.
            deviceName: TfArg.literal('langfuse-data'),
          ),
        ],
        networkInterface: [
          ComputeInstanceNetworkInterface(
            subnetwork: TfArg.ref(subnet.id),
          ),
        ],
        serviceAccount: ComputeInstanceServiceAccount(
          email: TfArg.ref(vmSa.email),
          scopes: const ['cloud-platform'],
        ),
        scheduling: spot
            ? ComputeInstanceScheduling(
                provisioningModel: ProvisioningModel.spot,
                preemptible: TfArg.literal(true),
                automaticRestart: TfArg.literal(false),
                onHostMaintenance: OnHostMaintenance.terminate,
                instanceTerminationAction: InstanceTerminationAction.stop,
              )
            : ComputeInstanceScheduling(
                provisioningModel: ProvisioningModel.standard,
                automaticRestart: TfArg.literal(true),
                onHostMaintenance: OnHostMaintenance.migrate,
              ),
        shieldedInstanceConfig: ComputeInstanceShieldedInstanceConfig(
          enableSecureBoot: TfArg.literal(true),
          enableVtpm: TfArg.literal(true),
          enableIntegrityMonitoring: TfArg.literal(true),
        ),
        metadata: TfArg.literal({
          'enable-oslogin': 'TRUE',
          'startup-script': _escapeTemplate(startupScript),
          'shutdown-script': _escapeTemplate(shutdownScript),
        }),
        project: project,
      ),
    );

    // --- Spot recovery: start the VM every 5 minutes (no-op when running) --
    // `vm-power.yml` pauses this job to keep the VM stopped on purpose, so
    // the paused flag is operational state that Terraform must not reset.
    final starterSa = add(
      GoogleServiceAccount(
        localName: 'starter',
        accountId: TfArg.literal('langfuse-starter'),
        displayName: TfArg.literal('Langfuse VM starter (Cloud Scheduler)'),
        project: project,
      ),
    );

    add(
      GoogleComputeInstanceIamMember(
        localName: 'starter_can_start_vm',
        instanceName: TfArg.ref(vm.nameRef),
        zone: TfArg.literal(zone),
        role: TfArg.literal('roles/compute.instanceAdmin.v1'),
        member: TfArg.ref(starterSa.iamMember),
        project: project,
      ),
    );

    add(
      GoogleCloudSchedulerJob(
        localName: 'start_vm',
        name: TfArg.literal('langfuse-start-vm'),
        region: TfArg.literal(region),
        description: TfArg.literal(
          'Restarts the Langfuse Spot VM after preemption.',
        ),
        schedule: TfArg.literal('*/5 * * * *'),
        timeZone: TfArg.literal('Etc/UTC'),
        attemptDeadline: TfArg.literal('60s'),
        target: CloudSchedulerJobHttpTarget(
          uri: TfArg.literal(
            'https://compute.googleapis.com/compute/v1/projects/$projectId'
            '/zones/$zone/instances/langfuse/start',
          ),
          httpMethod: TfArg.literal('POST'),
          oauthToken: CloudSchedulerJobHttpOauthToken(
            serviceAccountEmail: TfArg.ref(starterSa.email),
            scope: TfArg.literal(
              'https://www.googleapis.com/auth/cloud-platform',
            ),
          ),
        ),
        project: project,
        lifecycle: const LifecycleOptions(ignoreChanges: ['paused']),
      ),
    );

    // --- Cloudflare: tunnel, DNS, Access ------------------------------------
    final cfZone = addData(
      DataCloudflareZone(
        localName: 'koborin',
        filter: DataZoneFilter(name: TfArg.literal(zoneName)),
      ),
    );

    final tunnel = add(
      CloudflareZeroTrustTunnelCloudflared(
        localName: 'langfuse',
        accountId: cfAccount,
        name: TfArg.literal('langfuse'),
        configSrc: TfArg.literal('cloudflare'),
      ),
    );

    add(
      CloudflareZeroTrustTunnelCloudflaredConfig(
        localName: 'langfuse',
        accountId: cfAccount,
        tunnelId: TfArg.ref(tunnel.id),
        config: ZeroTrustTunnelCloudflaredConfigConfig(
          ingress: [
            // `langfuse-web` resolves on the Compose network cloudflared
            // shares with it; port 3000 is never published on the host.
            ZeroTrustTunnelCloudflaredConfigConfigIngress(
              hostname: TfArg.literal(hostname),
              service: TfArg.literal('http://langfuse-web:3000'),
            ),
            ZeroTrustTunnelCloudflaredConfigConfigIngress(
              service: TfArg.literal('http_status:404'),
            ),
          ],
        ),
      ),
    );

    final tunnelToken = addData(
      DataCloudflareZeroTrustTunnelCloudflaredToken(
        localName: 'langfuse',
        accountId: cfAccount,
        tunnelId: TfArg.ref(tunnel.id),
      ),
    );

    add(
      GoogleSecretManagerSecretVersion(
        localName: 'cloudflared_token',
        secret: TfArg.ref(tunnelSecret.id),
        secretDataWo: TfArg.ref(tunnelToken.token),
        secretDataWoVersion: TfArg.literal(1),
        // Write-only data is not diffed, so a replaced tunnel must force a
        // new version explicitly.
        lifecycle: LifecycleOptions(replaceTriggeredBy: [tunnel.id]),
      ),
    );

    add(
      CloudflareDnsRecord(
        localName: 'langfuse',
        zoneId: TfArg.ref(cfZone.id),
        name: TfArg.literal(hostname),
        type: TfArg.literal('CNAME'),
        content: TfArg.expression('${tunnel.id.interpolation}.cfargotunnel.com'),
        proxied: TfArg.literal(true),
        ttl: TfArg.literal(1),
        comment: TfArg.literal('Langfuse via Cloudflare Tunnel (koborin-ai/langfuse)'),
      ),
    );

    if (gateUiWithAccess) {
      final ownerOnly = add(
        CloudflareZeroTrustAccessPolicy(
          localName: 'owner_only',
          accountId: cfAccount,
          name: TfArg.literal('langfuse-owner-only'),
          decision: TfArg.literal('allow'),
          include: [
            ZeroTrustAccessPolicyInclude(
              email: ZeroTrustAccessPolicyIncludeEmail(email: ownerEmail),
            ),
          ],
          sessionDuration: TfArg.literal('24h'),
        ),
      );

      // SDKs and OTel exporters authenticate with Langfuse API keys, so the
      // public API bypasses Access. The more specific path wins over the
      // host-wide app below.
      final bypass = add(
        CloudflareZeroTrustAccessPolicy(
          localName: 'public_api_bypass',
          accountId: cfAccount,
          name: TfArg.literal('langfuse-public-api-bypass'),
          decision: TfArg.literal('bypass'),
          include: [
            ZeroTrustAccessPolicyInclude(
              everyone: const ZeroTrustAccessPolicyIncludeEveryone(),
            ),
          ],
        ),
      );

      add(
        CloudflareZeroTrustAccessApplication(
          localName: 'ui',
          accountId: cfAccount,
          name: TfArg.literal('Langfuse UI'),
          type: TfArg.literal('self_hosted'),
          domain: TfArg.literal(hostname),
          sessionDuration: TfArg.literal('24h'),
          policies: [
            ZeroTrustAccessApplicationPolicies(
              id: TfArg.ref(ownerOnly.id),
              precedence: TfArg.literal(1),
            ),
          ],
        ),
      );

      add(
        CloudflareZeroTrustAccessApplication(
          localName: 'public_api',
          accountId: cfAccount,
          name: TfArg.literal('Langfuse public API'),
          type: TfArg.literal('self_hosted'),
          domain: TfArg.literal('$hostname/api/public'),
          policies: [
            ZeroTrustAccessApplicationPolicies(
              id: TfArg.ref(bypass.id),
              precedence: TfArg.literal(1),
            ),
          ],
        ),
      );
    }

    // --- Cloudflare R2: Langfuse blob storage and off-GCP backups ----------
    final blob = add(
      CloudflareR2Bucket(
        localName: 'blob',
        accountId: cfAccount,
        name: TfArg.literal('langfuse-blob'),
        location: TfArg.literal('apac'),
      ),
    );

    // Browsers upload media straight to R2 with presigned URLs.
    add(
      CloudflareR2BucketCors(
        localName: 'blob',
        accountId: cfAccount,
        bucketName: TfArg.ref(blob.nameRef),
        rules: [
          R2BucketCorsRules(
            allowed: R2BucketCorsRulesAllowed(
              origins: TfArg.literal(['https://$hostname']),
              methods: TfArg.literal(const ['GET', 'PUT']),
              headers: TfArg.literal(const ['*']),
            ),
            exposeHeaders: TfArg.literal(const ['ETag']),
            maxAgeSeconds: TfArg.literal(3600),
          ),
        ],
      ),
    );

    final backups = add(
      CloudflareR2Bucket(
        localName: 'backups',
        accountId: cfAccount,
        name: TfArg.literal('langfuse-backups'),
        location: TfArg.literal('apac'),
      ),
    );

    add(
      CloudflareR2BucketLifecycle(
        localName: 'backups',
        accountId: cfAccount,
        bucketName: TfArg.ref(backups.nameRef),
        rules: [
          R2BucketLifecycleRules(
            id: TfArg.literal('expire-after-30-days'),
            enabled: TfArg.literal(true),
            conditions: R2BucketLifecycleRulesConditions(
              prefix: TfArg.literal(''),
            ),
            deleteObjectsTransition: R2BucketLifecycleRulesDeleteObjectsTransition(
              condition: R2BucketLifecycleRulesDeleteObjectsTransitionCondition(
                type: TfArg.literal('Age'),
                maxAge: TfArg.literal(30 * 24 * 60 * 60),
              ),
            ),
          ),
        ],
      ),
    );

    // --- Monitoring -------------------------------------------------------
    final email = add(
      GoogleMonitoringNotificationChannel(
        localName: 'owner_email',
        displayName: TfArg.literal('Langfuse owner'),
        type: TfArg.literal('email'),
        labels: TfArg.literal({'email_address': r'${var.owner_email}'}),
        project: project,
      ),
    );
    final channels = TfArg.literal([email.id.interpolation]);

    final health = add(
      GoogleMonitoringUptimeCheckConfig(
        localName: 'health',
        displayName: TfArg.literal('langfuse /api/public/health'),
        timeout: TfArg.literal('10s'),
        period: TfArg.literal('300s'),
        selectedRegions: const [
          MonitoringUptimeCheckRegion.asiaPacific,
          MonitoringUptimeCheckRegion.usa,
          MonitoringUptimeCheckRegion.europe,
        ],
        target: MonitoringUptimeCheckConfigMonitoredResource(
          type: TfArg.literal('uptime_url'),
          labels: {'host': hostname, 'project_id': projectId},
        ),
        httpCheck: MonitoringUptimeCheckConfigHttpCheck(
          path: TfArg.literal('/api/public/health'),
          port: TfArg.literal(443),
          useSsl: TfArg.literal(true),
          validateSsl: TfArg.literal(true),
        ),
        project: project,
      ),
    );

    // 15 minutes of failures before paging: a Spot preemption plus the
    // 5-minute Scheduler restart and Compose boot stays under that.
    // `vm-power.yml` disables this policy while the VM is stopped on purpose
    // and finds it by display name, so `enabled` is left to the workflow.
    add(
      GoogleMonitoringAlertPolicy(
        localName: 'uptime',
        displayName: TfArg.literal('Langfuse is unreachable'),
        combiner: TfArg.literal(AlertCombiner.or),
        severity: TfArg.literal(AlertSeverity.critical),
        notificationChannels: channels,
        conditions: [
          MonitoringAlertPolicyAlertCondition(
            displayName: TfArg.literal('Uptime check failing'),
            conditionThreshold: MonitoringAlertPolicyConditionThreshold(
              filter: TfArg.expression(
                'metric.type="monitoring.googleapis.com/uptime_check/check_passed"'
                ' AND resource.type="uptime_url"'
                ' AND metric.label.check_id="${health.uptimeCheckId.interpolation}"',
              ),
              comparison: TfArg.literal(Comparison.lessThan),
              thresholdValue: TfArg.literal(0.5),
              duration: TfArg.literal('900s'),
              aggregations: [
                MonitoringAlertPolicyAggregation(
                  alignmentPeriod: TfArg.literal('300s'),
                  perSeriesAligner: Aligner.fractionTrue,
                  crossSeriesReducer: Reducer.mean,
                  groupByFields: TfArg.literal(const ['resource.label.host']),
                ),
              ],
            ),
          ),
        ],
        project: project,
        lifecycle: const LifecycleOptions(ignoreChanges: ['enabled']),
      ),
    );

    // Needs the Ops Agent, which vm/startup.sh installs. ClickHouse stops
    // accepting writes when its disk fills up.
    add(
      GoogleMonitoringAlertPolicy(
        localName: 'disk',
        displayName: TfArg.literal('Langfuse VM disk above 80%'),
        combiner: TfArg.literal(AlertCombiner.or),
        severity: TfArg.literal(AlertSeverity.warning),
        notificationChannels: channels,
        conditions: [
          MonitoringAlertPolicyAlertCondition(
            displayName: TfArg.literal('Disk used > 80%'),
            conditionThreshold: MonitoringAlertPolicyConditionThreshold(
              filter: TfArg.literal(
                'metric.type="agent.googleapis.com/disk/percent_used"'
                ' AND resource.type="gce_instance"'
                ' AND metric.label.state="used"'
                ' AND metadata.system_labels.name="langfuse"',
              ),
              comparison: TfArg.literal(Comparison.greaterThan),
              thresholdValue: TfArg.literal(80),
              duration: TfArg.literal('600s'),
              aggregations: [
                MonitoringAlertPolicyAggregation(
                  alignmentPeriod: TfArg.literal('300s'),
                  perSeriesAligner: Aligner.mean,
                ),
              ],
            ),
          ),
        ],
        project: project,
      ),
    );

    add(
      GoogleMonitoringAlertPolicy(
        localName: 'memory',
        displayName: TfArg.literal('Langfuse VM memory above 90%'),
        combiner: TfArg.literal(AlertCombiner.or),
        severity: TfArg.literal(AlertSeverity.warning),
        notificationChannels: channels,
        conditions: [
          MonitoringAlertPolicyAlertCondition(
            displayName: TfArg.literal('Memory used > 90%'),
            conditionThreshold: MonitoringAlertPolicyConditionThreshold(
              filter: TfArg.literal(
                'metric.type="agent.googleapis.com/memory/percent_used"'
                ' AND resource.type="gce_instance"'
                ' AND metric.label.state="used"'
                ' AND metadata.system_labels.name="langfuse"',
              ),
              comparison: TfArg.literal(Comparison.greaterThan),
              thresholdValue: TfArg.literal(90),
              duration: TfArg.literal('600s'),
              aggregations: [
                MonitoringAlertPolicyAggregation(
                  alignmentPeriod: TfArg.literal('300s'),
                  perSeriesAligner: Aligner.mean,
                ),
              ],
            ),
          ),
        ],
        project: project,
      ),
    );
  }
}

/// tf.json treats every string as a template, so shell `${VAR}` and `%{`
/// must be escaped to reach the VM verbatim.
String _escapeTemplate(String text) =>
    text.replaceAll(r'${', r'$${').replaceAll('%{', '%%{');
