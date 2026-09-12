import '../config/bpp_client_config.dart';
import '../integration/segmentation_classification_port.dart';
import 'frontend_pipeline_coordinator.dart';
import 'gloss_lattice_connection_factory.dart';
import 'gloss_lattice_frontend_session.dart';
import 'gloss_lattice_session_client.dart';
import 'gloss_lattice_websocket_client.dart';
import 'tracking_service.dart';

/// Composition root for BPP Section 6 on native Flutter clients.
///
/// The caller supplies the real Stage 5/6 classifier. This class owns session
/// negotiation, the authenticated lattice socket, processed-frame delivery,
/// and shutdown/reconnect order. It deliberately has no fallback classifier:
/// sending guessed or raw landmark data would violate the contract.
final class BppClientIntegration {
  BppClientIntegration._({
    required this.session,
    required this.pipeline,
    required this.sessionClient,
  });

  static Future<BppClientIntegration> connect({
    required BppClientConfig config,
    required TrackingService tracking,
    required SegmentationClassificationPort recognition,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final sessionClient = GlossLatticeSessionClient(
      baseUri: config.httpsBaseUri,
      requestTimeout: config.sessionTimeout,
    );
    try {
      final session = await GlossLatticeFrontendSession.connect(
        request: config.toSessionRequest(),
        sessionClient: sessionClient,
        connectionFactory: GlossLatticeConnectionFactory(
          connectTimeout: config.connectTimeout,
          responseTimeout: config.responseTimeout,
          websocketBaseUri: config.wssBaseUri,
          onEvent: onEvent,
        ),
      );
      final pipeline = FrontendPipelineCoordinator(
        tracking: tracking,
        recognition: recognition,
        submissions: session.submissions,
      );
      session.submissions.configureRetry(
        maxRetries: config.maxRetries,
        reconnect: session.reconnect,
      );
      return BppClientIntegration._(
        session: session,
        pipeline: pipeline,
        sessionClient: sessionClient,
      );
    } on Object {
      sessionClient.close();
      rethrow;
    }
  }

  final GlossLatticeFrontendSession session;
  final FrontendPipelineCoordinator pipeline;
  final GlossLatticeSessionClient sessionClient;

  Stream<GlossLatticeSubmissionReceipt> get receipts => pipeline.receipts;

  Future<void> start() => pipeline.start();

  Future<void> stop() => pipeline.stop();

  Future<void> reconnect() => session.reconnect();

  Future<GlossLatticeSubmissionReceipt> retryPending() =>
      session.submissions.retryPending();

  Future<void> end() async {
    await pipeline.stop();
    await session.end();
  }

  Future<void> close() async {
    await pipeline.close();
    await session.close();
    sessionClient.close();
  }
}
