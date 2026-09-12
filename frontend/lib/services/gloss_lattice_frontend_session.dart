import '../adapters/gloss_lattice_builder.dart';
import '../contracts/gloss_lattice_session.dart';
import 'gloss_lattice_connection_factory.dart';
import 'gloss_lattice_session_client.dart';
import 'gloss_lattice_session_coordinator.dart';
import 'gloss_lattice_submission_service.dart';

/// One negotiated frontend-to-backend GlossLattice session.
///
/// This is the composition root for transport: create the HTTP session, open
/// its authenticated WebSocket, bind the exact producer/language profile, and
/// expose the submission service used by the frontend pipeline.
final class GlossLatticeFrontendSession {
  GlossLatticeFrontendSession._({
    required this.negotiated,
    required this.coordinator,
    required this.submissions,
    required this._sessionClient,
    required this._connectionFactory,
  });

  final GlossLatticeSessionCreateResponse negotiated;
  final GlossLatticeSessionCoordinator coordinator;
  final GlossLatticeSubmissionService submissions;
  final GlossLatticeSessionClient _sessionClient;
  final GlossLatticeConnectionFactory _connectionFactory;
  bool _closed = false;

  static Future<GlossLatticeFrontendSession> connect({
    required GlossLatticeSessionCreateRequest request,
    required GlossLatticeSessionClient sessionClient,
    GlossLatticeConnectionFactory? connectionFactory,
    GlossLatticeSessionCoordinator? coordinator,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final sessionCoordinator =
        coordinator ?? GlossLatticeSessionCoordinator.start();
    // The clock is deliberately established before session negotiation.
    sessionCoordinator.nowMs();
    final negotiated = await sessionClient.createSession(request);
    final resolvedConnectionFactory =
        connectionFactory ?? GlossLatticeConnectionFactory(onEvent: onEvent);
    final websocket = await resolvedConnectionFactory.connect(
      // Session negotiation and bearer-token use are deliberately pinned
      // to one origin so a token cannot be sent to a different host.
      baseUri: sessionClient.baseUri,
      session: negotiated,
    );
    try {
      await websocket.waitForInitialIdle();
    } catch (_) {
      await websocket.close();
      rethrow;
    }
    final builder = GlossLatticeBuilder(
      sessionId: negotiated.sessionId,
      language: request.language,
      producer: request.producer,
    );
    return GlossLatticeFrontendSession._(
      negotiated: negotiated,
      coordinator: sessionCoordinator,
      sessionClient: sessionClient,
      connectionFactory: resolvedConnectionFactory,
      submissions: GlossLatticeSubmissionService(
        builder: builder,
        websocketClient: websocket,
        sessionCoordinator: sessionCoordinator,
      ),
    );
  }

  /// Opens a fresh authenticated socket for the same negotiated session.
  /// Any pending lattice remains byte-for-byte unchanged for cached replay.
  Future<void> reconnect() async {
    if (_closed) {
      throw StateError('The GlossLattice frontend session is closed.');
    }
    final replacement = await _connectionFactory.connect(
      baseUri: _sessionClient.baseUri,
      session: negotiated,
    );
    try {
      await replacement.waitForInitialIdle();
      await submissions.replaceWebsocketClient(replacement);
    } catch (_) {
      await replacement.close();
      rethrow;
    }
  }

  /// Ends the session through the WebSocket, then uses authenticated DELETE
  /// only if the socket did not close normally.
  Future<void> end() async {
    if (_closed) return;
    _closed = true;
    var socketClosedNormally = false;
    try {
      socketClosedNormally = await submissions.websocketClient.end(
        controlSeq: coordinator.nextControlSeq(),
        clientMs: coordinator.nowMs(),
      );
    } finally {
      await submissions.close();
      if (!socketClosedNormally) {
        await _sessionClient.deleteSession(negotiated);
      }
      _sessionClient.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await submissions.close();
    _sessionClient.close();
  }
}
