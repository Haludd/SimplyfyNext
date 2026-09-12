import 'package:apptesting/config/bpp_client_config.dart';
import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/contracts/gloss_lattice_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds a strict session request from non-secret client values', () {
    final config = BppClientConfig(
      httpsBaseUri: Uri.parse('https://api.example'),
      wssBaseUri: Uri.parse('wss://api.example'),
      language: GlossLatticeLanguage.asl,
      producer: GlossLatticeProducer(
        classifierId: 'classifier',
        classifierVersion: 'v1',
        calibrationVersion: 'cal-v1',
        vocabularyVersion: 'v1',
      ),
      client: GlossLatticeClientDescriptor(
        platform: GlossLatticeClientPlatform.ios,
        appVersion: '1.0.0',
      ),
      detector: GlossLatticeDetectorDescriptor(
        name: 'mediapipe',
        version: '0.10.35',
        delegate: GlossLatticeDetectorDelegate.coreMl,
      ),
    );

    final request = config.toSessionRequest();
    expect(request.language, GlossLatticeLanguage.asl);
    expect(request.producer.classifierId, 'classifier');
    expect(request.client.platform, GlossLatticeClientPlatform.ios);
    expect(request.detector.delegate, GlossLatticeDetectorDelegate.coreMl);
  });

  test('rejects HTTPS and WSS origins that do not match', () {
    expect(
      () => BppClientConfig(
        httpsBaseUri: Uri.parse('https://api.example'),
        wssBaseUri: Uri.parse('wss://other.example'),
        language: GlossLatticeLanguage.asl,
        producer: GlossLatticeProducer(
          classifierId: 'classifier',
          classifierVersion: 'v1',
          calibrationVersion: 'cal-v1',
          vocabularyVersion: 'v1',
        ),
        client: GlossLatticeClientDescriptor(
          platform: GlossLatticeClientPlatform.android,
          appVersion: '1.0.0',
        ),
        detector: GlossLatticeDetectorDescriptor(
          name: 'mediapipe',
          version: '0.10.35',
        ),
      ),
      throwsArgumentError,
    );
  });
}
