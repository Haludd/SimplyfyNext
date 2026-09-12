import 'dart:convert';

import 'gloss_lattice.dart';

/// The separately versioned server-to-client lattice event protocol.
abstract final class GlossLatticeEventContract {
  static const String schemaVersion = '1.0';
}

enum GlossLatticeActivityState {
  idle('idle'),
  signing('signing'),
  processing('processing');

  const GlossLatticeActivityState(this.wireValue);

  final String wireValue;

  static GlossLatticeActivityState fromWireValue(String value) => switch (
    value
  ) {
    'idle' => GlossLatticeActivityState.idle,
    'signing' => GlossLatticeActivityState.signing,
    'processing' => GlossLatticeActivityState.processing,
    _ => throw GlossLatticeEventValidationException(
      'activity state is unsupported: "$value"',
    ),
  };
}

enum GlossLatticeRepairAction {
  askRepeat('ask_repeat'),
  requestFingerspelling('request_fingerspelling'),
  offerTopK('offer_top_k'),
  escalateHumanInterpreter('escalate_human_interpreter');

  const GlossLatticeRepairAction(this.wireValue);

  final String wireValue;

  static GlossLatticeRepairAction fromWireValue(String value) => switch (
    value
  ) {
    'ask_repeat' => GlossLatticeRepairAction.askRepeat,
    'request_fingerspelling' =>
      GlossLatticeRepairAction.requestFingerspelling,
    'offer_top_k' => GlossLatticeRepairAction.offerTopK,
    'escalate_human_interpreter' =>
      GlossLatticeRepairAction.escalateHumanInterpreter,
    _ => throw GlossLatticeEventValidationException(
      'repair action is unsupported: "$value"',
    ),
  };
}

/// Raised when the backend sends an event that is not part of lattice events
/// v1. A malformed event is surfaced to the UI; it is never treated as text.
final class GlossLatticeEventValidationException implements Exception {
  const GlossLatticeEventValidationException(this.message);

  final String message;

  @override
  String toString() => 'GlossLatticeEventValidationException: $message';
}

sealed class GlossLatticeBackendEvent {
  const GlossLatticeBackendEvent({
    required this.eventSchemaVersion,
    required this.sessionId,
  });

  static GlossLatticeBackendEvent fromJson(Map<String, dynamic> json) {
    final type = _requiredString(json, 'type');
    return switch (type) {
      'activity' => GlossLatticeActivityEvent.fromJson(json),
      'lattice_ack' => GlossLatticeAckEvent.fromJson(json),
      'lattice_result' => GlossLatticeResultEvent.fromJson(json),
      'lattice_repair_required' =>
        GlossLatticeRepairRequiredEvent.fromJson(json),
      'pong' => GlossLatticePongEvent.fromJson(json),
      'error' => GlossLatticeErrorEvent.fromJson(json),
      _ => throw GlossLatticeEventValidationException(
        'unknown lattice event type: "$type"',
      ),
    };
  }

  static GlossLatticeBackendEvent fromWireJson(String source) {
    final byteLength = utf8.encode(source).length;
    if (byteLength > GlossLatticeContract.maxMessageBytes) {
      throw const GlossLatticeEventValidationException(
        'lattice event exceeds the 32768-byte limit',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw GlossLatticeEventValidationException(
        'lattice event is not valid JSON: ${error.message}',
      );
    }
    return fromJson(_object(decoded, 'event'));
  }

  final String eventSchemaVersion;
  final String sessionId;

}

final class GlossLatticeActivityEvent extends GlossLatticeBackendEvent {
  GlossLatticeActivityEvent._({
    required super.eventSchemaVersion,
    required super.sessionId,
    required this.state,
    required this.latticeSeq,
    required this.utteranceId,
    required this.serverMs,
  });

  factory GlossLatticeActivityEvent.fromJson(Map<String, dynamic> json) {
    const expected = <String>{
      'type',
      'event_schema_version',
      'session_id',
      'state',
      'lattice_seq',
      'utterance_id',
      'server_ms',
    };
    final base = _baseEnvelope(json, expected);
    final latticeSeq = _optionalSafeInt(json, 'lattice_seq');
    final utteranceId = _optionalIdentifier(json, 'utterance_id');
    if ((latticeSeq == null) != (utteranceId == null)) {
      throw const GlossLatticeEventValidationException(
        'activity lattice_seq and utterance_id must be supplied together',
      );
    }
    final state = GlossLatticeActivityState.fromWireValue(
      _requiredString(json, 'state'),
    );
    if (state == GlossLatticeActivityState.processing && latticeSeq == null) {
      throw const GlossLatticeEventValidationException(
        'processing activity requires lattice correlation',
      );
    }
    return GlossLatticeActivityEvent._(
      eventSchemaVersion: base.$1,
      sessionId: base.$2,
      state: state,
      latticeSeq: latticeSeq,
      utteranceId: utteranceId,
      serverMs: _requiredSafeInt(json, 'server_ms'),
    );
  }

  final GlossLatticeActivityState state;
  final int? latticeSeq;
  final String? utteranceId;
  final int serverMs;
}

final class GlossLatticeAckEvent extends GlossLatticeBackendEvent {
  GlossLatticeAckEvent._({
    required super.eventSchemaVersion,
    required super.sessionId,
    required this.latticeSeq,
    required this.utteranceId,
    required this.disposition,
    required this.serverMs,
  });

  factory GlossLatticeAckEvent.fromJson(Map<String, dynamic> json) {
    const expected = <String>{
      'type',
      'event_schema_version',
      'session_id',
      'lattice_seq',
      'utterance_id',
      'disposition',
      'server_ms',
    };
    final base = _baseEnvelope(json, expected);
    final disposition = _requiredString(json, 'disposition');
    if (disposition != 'accepted' && disposition != 'cached') {
      throw const GlossLatticeEventValidationException(
        'lattice_ack disposition must be accepted or cached',
      );
    }
    return GlossLatticeAckEvent._(
      eventSchemaVersion: base.$1,
      sessionId: base.$2,
      latticeSeq: _requiredSafeInt(json, 'lattice_seq'),
      utteranceId: _requiredIdentifier(json, 'utterance_id'),
      disposition: disposition,
      serverMs: _requiredSafeInt(json, 'server_ms'),
    );
  }

  final int latticeSeq;
  final String utteranceId;
  final String disposition;
  final int serverMs;
}

final class GlossLatticePongEvent extends GlossLatticeBackendEvent {
  GlossLatticePongEvent._({
    required super.eventSchemaVersion,
    required super.sessionId,
    required this.controlSeq,
    required this.serverMs,
  });

  factory GlossLatticePongEvent.fromJson(Map<String, dynamic> json) {
    const expected = <String>{
      'type',
      'event_schema_version',
      'session_id',
      'control_seq',
      'server_ms',
    };
    final base = _baseEnvelope(json, expected);
    return GlossLatticePongEvent._(
      eventSchemaVersion: base.$1,
      sessionId: base.$2,
      controlSeq: _requiredSafeInt(json, 'control_seq'),
      serverMs: _requiredSafeInt(json, 'server_ms'),
    );
  }

  final int controlSeq;
  final int serverMs;
}

final class GlossLatticeErrorEvent extends GlossLatticeBackendEvent {
  GlossLatticeErrorEvent._({
    required super.eventSchemaVersion,
    required super.sessionId,
    required this.code,
    required this.message,
    required this.retryable,
    required this.latticeSeq,
    required this.utteranceId,
  });

  factory GlossLatticeErrorEvent.fromJson(Map<String, dynamic> json) {
    const expected = <String>{
      'type',
      'event_schema_version',
      'session_id',
      'code',
      'message',
      'retryable',
      'lattice_seq',
      'utterance_id',
    };
    final base = _baseEnvelope(json, expected);
    final code = _requiredString(json, 'code');
    const allowed = <String>{
      'invalid_message',
      'unauthorized',
      'session_not_found',
      'session_expired',
      'invalid_session_state',
      'non_monotonic_sequence',
      'batch_too_large',
      'rate_limited',
      'internal_error',
    };
    if (!allowed.contains(code)) {
      throw GlossLatticeEventValidationException(
        'error code is unsupported: "$code"',
      );
    }
    final retryable = json['retryable'];
    if (retryable is! bool) {
      throw const GlossLatticeEventValidationException(
        'error.retryable must be a JSON boolean',
      );
    }
    final latticeSeq = _optionalSafeInt(json, 'lattice_seq');
    final utteranceId = _optionalIdentifier(json, 'utterance_id');
    if ((latticeSeq == null) != (utteranceId == null)) {
      throw const GlossLatticeEventValidationException(
        'error lattice_seq and utterance_id must be supplied together',
      );
    }
    return GlossLatticeErrorEvent._(
      eventSchemaVersion: base.$1,
      sessionId: base.$2,
      code: code,
      message: _requiredString(json, 'message'),
      retryable: retryable,
      latticeSeq: latticeSeq,
      utteranceId: utteranceId,
    );
  }

  final String code;
  final String message;
  final bool retryable;
  final int? latticeSeq;
  final String? utteranceId;
}

final class GlossLatticeEvidenceTrace {
  GlossLatticeEvidenceTrace({
    required this.slotIndex,
    required this.slotId,
    required this.startMs,
    required this.endMs,
    required this.resolvedGlossId,
    required this.confidence,
    required this.provenance,
    required List<GlossCandidate> candidates,
  }) : candidates = List<GlossCandidate>.unmodifiable(candidates) {
    if (endMs <= startMs) {
      throw const GlossLatticeEventValidationException(
        'evidence end_ms must be greater than start_ms',
      );
    }
    if (provenance == GlossProvenance.unresolved && confidence != null) {
      throw const GlossLatticeEventValidationException(
        'unresolved evidence cannot contain confidence',
      );
    }
  }

  factory GlossLatticeEvidenceTrace.fromJson(Map<String, dynamic> json) {
    const expected = <String>{
      'slot_index',
      'slot_id',
      'start_ms',
      'end_ms',
      'resolved_gloss_id',
      'confidence',
      'provenance',
      'candidates',
    };
    _expectExactKeys(json, expected, 'evidence_trace item');
    final rawCandidates = _requiredList(json, 'candidates');
    if (rawCandidates.length > GlossLatticeContract.maxCandidatesPerSlot) {
      throw const GlossLatticeEventValidationException(
        'evidence candidates exceed the v1 limit',
      );
    }
    final candidates = <GlossCandidate>[
      for (var index = 0; index < rawCandidates.length; index += 1)
        GlossCandidate.fromJson(
          _object(rawCandidates[index], 'candidates[$index]'),
          path: 'candidates[$index]',
        ),
    ];
    final resolved = json['resolved_gloss_id'];
    if (resolved != null && resolved is! String) {
      throw const GlossLatticeEventValidationException(
        'evidence resolved_gloss_id must be a string or null',
      );
    }
    final rawConfidence = json['confidence'];
    final confidence = rawConfidence == null
        ? null
        : _number(rawConfidence, 'confidence');
    return GlossLatticeEvidenceTrace(
      slotIndex: _requiredSafeInt(json, 'slot_index'),
      slotId: _requiredIdentifier(json, 'slot_id'),
      startMs: _requiredSafeInt(json, 'start_ms'),
      endMs: _requiredSafeInt(json, 'end_ms'),
      resolvedGlossId: resolved as String?,
      confidence: confidence,
      provenance: GlossProvenance.fromWireValue(
        _requiredString(json, 'provenance'),
      ),
      candidates: candidates,
    );
  }

  final int slotIndex;
  final String slotId;
  final int startMs;
  final int endMs;
  final String? resolvedGlossId;
  final double? confidence;
  final GlossProvenance provenance;
  final List<GlossCandidate> candidates;
}

final class GlossLatticeChoice {
  GlossLatticeChoice({
    required this.slotId,
    required this.rank,
    required this.glossId,
    required this.confidence,
  });

  factory GlossLatticeChoice.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const <String>{
      'slot_id',
      'rank',
      'gloss_id',
      'confidence',
    }, 'choice');
    return GlossLatticeChoice(
      slotId: _requiredIdentifier(json, 'slot_id'),
      rank: _requiredSafeInt(json, 'rank'),
      glossId: _requiredIdentifier(json, 'gloss_id'),
      confidence: _number(json['confidence'], 'confidence'),
    );
  }

  final String slotId;
  final int rank;
  final String glossId;
  final double confidence;
}

final class GlossLatticeResultEvent extends GlossLatticeBackendEvent {
  GlossLatticeResultEvent._({
    required super.eventSchemaVersion,
    required super.sessionId,
    required this.latticeSeq,
    required this.utteranceId,
    required this.caption,
    required this.ttsText,
    required this.confidence,
    required List<String> glossIdTrace,
    required List<GlossLatticeEvidenceTrace> evidenceTrace,
    required this.classifierVersion,
    required this.agentSource,
    required this.agentModelVersion,
    required Map<String, int> latencyMs,
  }) : glossIdTrace = List<String>.unmodifiable(glossIdTrace),
       evidenceTrace = List<GlossLatticeEvidenceTrace>.unmodifiable(
         evidenceTrace,
       ),
       latencyMs = Map<String, int>.unmodifiable(latencyMs);

  factory GlossLatticeResultEvent.fromJson(Map<String, dynamic> json) {
    const expected = <String>{
      'type',
      'event_schema_version',
      'session_id',
      'lattice_seq',
      'utterance_id',
      'status',
      'caption',
      'tts_text',
      'confidence',
      'gloss_id_trace',
      'evidence_trace',
      'classifier_version',
      'agent_source',
      'agent_model_version',
      'latency_ms',
    };
    final base = _baseEnvelope(json, expected);
    if (_requiredString(json, 'status') != 'confident') {
      throw const GlossLatticeEventValidationException(
        'lattice_result status must be confident',
      );
    }
    final glossIdTrace = _requiredStringList(json, 'gloss_id_trace');
    final evidence = _evidenceList(json);
    _validateEvidenceOrder(evidence);
    final resolved = evidence
        .map((item) => item.resolvedGlossId)
        .whereType<String>()
        .toList(growable: false);
    if (!_sameStrings(glossIdTrace, resolved)) {
      throw const GlossLatticeEventValidationException(
        'gloss_id_trace must match resolved evidence order',
      );
    }
    if (evidence.any(
      (item) => item.provenance == GlossProvenance.unresolved,
    )) {
      throw const GlossLatticeEventValidationException(
        'a confident result cannot contain unresolved evidence',
      );
    }
    return GlossLatticeResultEvent._(
      eventSchemaVersion: base.$1,
      sessionId: base.$2,
      latticeSeq: _requiredSafeInt(json, 'lattice_seq'),
      utteranceId: _requiredIdentifier(json, 'utterance_id'),
      caption: _requiredString(json, 'caption'),
      ttsText: _optionalString(json, 'tts_text'),
      confidence: _number(json['confidence'], 'confidence'),
      glossIdTrace: glossIdTrace,
      evidenceTrace: evidence,
      classifierVersion: _requiredIdentifier(json, 'classifier_version'),
      agentSource: _optionalIdentifier(json, 'agent_source'),
      agentModelVersion: _optionalIdentifier(json, 'agent_model_version'),
      latencyMs: _latencyMap(json['latency_ms']),
    );
  }

  final int latticeSeq;
  final String utteranceId;
  final String caption;
  final String? ttsText;
  final double confidence;
  final List<String> glossIdTrace;
  final List<GlossLatticeEvidenceTrace> evidenceTrace;
  final String classifierVersion;
  final String? agentSource;
  final String? agentModelVersion;
  final Map<String, int> latencyMs;
}

final class GlossLatticeRepairRequiredEvent extends GlossLatticeBackendEvent {
  GlossLatticeRepairRequiredEvent._({
    required super.eventSchemaVersion,
    required super.sessionId,
    required this.latticeSeq,
    required this.utteranceId,
    required this.repairId,
    required this.action,
    required this.message,
    required this.confidence,
    required List<String> targetSlotIds,
    required List<GlossLatticeChoice> choices,
    required List<String> reasonCodes,
    required List<GlossLatticeEvidenceTrace> evidenceTrace,
    required this.classifierVersion,
    required this.agentSource,
    required this.agentModelVersion,
    required Map<String, int> latencyMs,
  }) : targetSlotIds = List<String>.unmodifiable(targetSlotIds),
       choices = List<GlossLatticeChoice>.unmodifiable(choices),
       reasonCodes = List<String>.unmodifiable(reasonCodes),
       evidenceTrace = List<GlossLatticeEvidenceTrace>.unmodifiable(
         evidenceTrace,
       ),
       latencyMs = Map<String, int>.unmodifiable(latencyMs);

  factory GlossLatticeRepairRequiredEvent.fromJson(
    Map<String, dynamic> json,
  ) {
    const expected = <String>{
      'type',
      'event_schema_version',
      'session_id',
      'lattice_seq',
      'utterance_id',
      'status',
      'repair_id',
      'action',
      'message',
      'confidence',
      'target_slot_ids',
      'choices',
      'reason_codes',
      'evidence_trace',
      'classifier_version',
      'agent_source',
      'agent_model_version',
      'latency_ms',
    };
    final base = _baseEnvelope(json, expected);
    if (_requiredString(json, 'status') != 'uncertain') {
      throw const GlossLatticeEventValidationException(
        'lattice_repair_required status must be uncertain',
      );
    }
    final targetSlotIds = _requiredStringList(json, 'target_slot_ids');
    final rawChoices = _requiredList(json, 'choices');
    final choices = <GlossLatticeChoice>[
      for (var index = 0; index < rawChoices.length; index += 1)
        GlossLatticeChoice.fromJson(
          _object(rawChoices[index], 'choices[$index]'),
        ),
    ];
    final evidence = _evidenceList(json);
    _validateEvidenceOrder(evidence);
    final action = GlossLatticeRepairAction.fromWireValue(
      _requiredString(json, 'action'),
    );
    if (action == GlossLatticeRepairAction.offerTopK &&
        (targetSlotIds.length != 1 || choices.isEmpty)) {
      throw const GlossLatticeEventValidationException(
        'offer_top_k requires one target slot and choices',
      );
    }
    if (action != GlossLatticeRepairAction.offerTopK && choices.isNotEmpty) {
      throw const GlossLatticeEventValidationException(
        'only offer_top_k may contain choices',
      );
    }
    return GlossLatticeRepairRequiredEvent._(
      eventSchemaVersion: base.$1,
      sessionId: base.$2,
      latticeSeq: _requiredSafeInt(json, 'lattice_seq'),
      utteranceId: _requiredIdentifier(json, 'utterance_id'),
      repairId: _requiredIdentifier(json, 'repair_id'),
      action: action,
      message: _requiredString(json, 'message'),
      confidence: _number(json['confidence'], 'confidence'),
      targetSlotIds: targetSlotIds,
      choices: choices,
      reasonCodes: _requiredStringList(json, 'reason_codes'),
      evidenceTrace: evidence,
      classifierVersion: _requiredIdentifier(json, 'classifier_version'),
      agentSource: _optionalIdentifier(json, 'agent_source'),
      agentModelVersion: _optionalIdentifier(json, 'agent_model_version'),
      latencyMs: _latencyMap(json['latency_ms']),
    );
  }

  final int latticeSeq;
  final String utteranceId;
  final String repairId;
  final GlossLatticeRepairAction action;
  final String message;
  final double confidence;
  final List<String> targetSlotIds;
  final List<GlossLatticeChoice> choices;
  final List<String> reasonCodes;
  final List<GlossLatticeEvidenceTrace> evidenceTrace;
  final String classifierVersion;
  final String? agentSource;
  final String? agentModelVersion;
  final Map<String, int> latencyMs;
}

(String, String) _baseEnvelope(
  Map<String, dynamic> json,
  Set<String> expected,
) {
  _expectExactKeys(json, expected, 'event');
  final version = _requiredString(json, 'event_schema_version');
  if (version != GlossLatticeEventContract.schemaVersion) {
    throw GlossLatticeEventValidationException(
      'event_schema_version must be "${GlossLatticeEventContract.schemaVersion}"',
    );
  }
  final sessionId = _requiredString(json, 'session_id');
  if (!GlossLatticeContract.isValidUuid(sessionId)) {
    throw const GlossLatticeEventValidationException(
      'event session_id must be a canonical UUID string',
    );
  }
  return (version, sessionId);
}

List<GlossLatticeEvidenceTrace> _evidenceList(Map<String, dynamic> json) {
  final raw = _requiredList(json, 'evidence_trace');
  if (raw.isEmpty || raw.length > GlossLatticeContract.maxSlots) {
    throw const GlossLatticeEventValidationException(
      'evidence_trace must contain 1 through 64 items',
    );
  }
  return <GlossLatticeEvidenceTrace>[
    for (var index = 0; index < raw.length; index += 1)
      GlossLatticeEvidenceTrace.fromJson(
        _object(raw[index], 'evidence_trace[$index]'),
      ),
  ];
}

void _validateEvidenceOrder(List<GlossLatticeEvidenceTrace> evidence) {
  final ids = <String>{};
  for (var index = 0; index < evidence.length; index += 1) {
    final item = evidence[index];
    if (item.slotIndex != index || !ids.add(item.slotId)) {
      throw const GlossLatticeEventValidationException(
        'evidence_trace slot indexes and IDs must be ordered and unique',
      );
    }
  }
}

Map<String, int> _latencyMap(Object? value) {
  final object = _object(value, 'latency_ms');
  final result = <String, int>{};
  for (final entry in object.entries) {
    result[entry.key] = _safeInt(entry.value, 'latency_ms.${entry.key}');
  }
  return result;
}

Map<String, dynamic> _object(Object? value, String path) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw GlossLatticeEventValidationException('$path must be a JSON object');
  }
  return Map<String, dynamic>.from(value);
}

List<dynamic> _requiredList(Map<String, dynamic> json, String path) {
  final value = json[path];
  if (value is! List) {
    throw GlossLatticeEventValidationException('$path must be a JSON array');
  }
  return value;
}

List<String> _requiredStringList(Map<String, dynamic> json, String path) =>
    _requiredList(json, path)
        .asMap()
        .entries
        .map((entry) => _string(entry.value, '$path[${entry.key}]'))
        .toList(growable: false);

String _requiredString(Map<String, dynamic> json, String path) =>
    _string(json[path], path);

String _string(Object? value, String path) {
  if (value is! String || value.isEmpty) {
    throw GlossLatticeEventValidationException('$path must be a non-empty string');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String path) {
  final value = json[path];
  if (value == null) return null;
  return _string(value, path);
}

String _requiredIdentifier(Map<String, dynamic> json, String path) {
  final value = _requiredString(json, path);
  if (!GlossLatticeContract.isValidIdentifier(value)) {
    throw GlossLatticeEventValidationException('$path is not a valid identifier');
  }
  return value;
}

String? _optionalIdentifier(Map<String, dynamic> json, String path) {
  final value = json[path];
  if (value == null) return null;
  if (value is! String || !GlossLatticeContract.isValidIdentifier(value)) {
    throw GlossLatticeEventValidationException('$path is not a valid identifier');
  }
  return value;
}

int _requiredSafeInt(Map<String, dynamic> json, String path) =>
    _safeInt(json[path], path);

int? _optionalSafeInt(Map<String, dynamic> json, String path) {
  final value = json[path];
  if (value == null) return null;
  return _safeInt(value, path);
}

int _safeInt(Object? value, String path) {
  if (value is! int ||
      value < 0 ||
      value > GlossLatticeContract.maxSafeJsonInteger) {
    throw GlossLatticeEventValidationException(
      '$path must be a safe non-negative integer',
    );
  }
  return value;
}

double _number(Object? value, String path) {
  if (value is! num) {
    throw GlossLatticeEventValidationException('$path must be a number');
  }
  final result = value.toDouble();
  if (!result.isFinite || result < 0 || result > 1) {
    throw GlossLatticeEventValidationException(
      '$path must be a finite number from 0.0 through 1.0',
    );
  }
  return result;
}

void _expectExactKeys(
  Map<String, dynamic> json,
  Set<String> expected,
  String path,
) {
  final actual = json.keys.toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw GlossLatticeEventValidationException(
      '$path has an unsupported property set; expected $expected, received $actual',
    );
  }
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
