import 'package:terradart_cloudflare/provider.dart';
import 'package:terradart_core/terradart_core.dart';
import 'package:terradart_google/provider.dart';

final class LangfuseStack extends Stack {
  LangfuseStack({
    required String projectId,
    required String region,
    required String zone,
    super.backend,
  }) : super(
          providers: [
            GoogleProvider(project: projectId, region: region, zone: zone),
            const CloudflareProvider(),
          ],
        );
}
