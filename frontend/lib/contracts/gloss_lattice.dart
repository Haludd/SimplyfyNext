import 'dart:convert';

/// Frozen constants and scalar rules for the frontend-to-backend
/// `GlossLattice` version 1.0 contract.
abstract final class GlossLatticeContract {
  static const String type = 'gloss_lattice';
  static const String schemaVersion = '1.0';
  static const String timebase = 'session_monotonic_ms';
  static const String confidenceKind = 'calibrated_probability';

  static const int maxMessageBytes = 32768;
  static const int maxSlots = 64;
  static const int maxCandidatesPerSlot = 5;
  static const int maxSafeJsonInteger = 9007199254740991;

  static final RegExp _identifierPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
  );
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );

  static bool isValidIdentifier(String value) =>
      _identifierPattern.hasMatch(value);

  static bool isValidUuid(String value) => _uuidPattern.hasMatch(value);
}

/// Raised before an invalid value can enter or leave the frozen wire model.
final class GlossLatticeValidationException implements Exception {
  const GlossLatticeValidationException(this.message);

  final String message;

  @override
  String toString() => 'GlossLatticeValidationException: $message';
}

enum GlossLatticeLanguage {
  sgsl('sgsl'),
  asl('asl');

  const GlossLatticeLanguage(this.wireValue);

  final String wireValue;

  static GlossLatticeLanguage fromWireValue(String value) => switch (value) {
    'sgsl' => GlossLatticeLanguage.sgsl,
    'asl' => GlossLatticeLanguage.asl,
    _ => _invalid('language must be either "sgsl" or "asl"'),
  };
}

enum GlossProvenance {
  classifierHighConfidence('classifier_high_confidence'),
  topKSignerConfirmed('top_k_signer_confirmed'),
  fingerspelled('fingerspelled'),
  unresolved('unresolved');

  const GlossProvenance(this.wireValue);

  final String wireValue;

  static GlossProvenance fromWireValue(String value) => switch (value) {
    'classifier_high_confidence' => GlossProvenance.classifierHighConfidence,
    'top_k_signer_confirmed' => GlossProvenance.topKSignerConfirmed,
    'fingerspelled' => GlossProvenance.fingerspelled,
    'unresolved' => GlossProvenance.unresolved,
    _ => _invalid('provenance has an unsupported value: "$value"'),
  };
}

/// Version lineage for the classifier, calibration, and vocabulary.
final class GlossLatticeProducer {
  GlossLatticeProducer({
    required this.classifierId,
    required this.classifierVersion,
    required this.calibrationVersion,
    required this.vocabularyVersion,
    this.confidenceKind = GlossLatticeContract.confidenceKind,
  }) {
    _validateIdentifier(classifierId, 'producer.classifier_id');
    _validateIdentifier(classifierVersion, 'producer.classifier_version');
    if (confidenceKind != GlossLatticeContract.confidenceKind) {
      _invalid(
        'producer.confidence_kind must be '
        '"${GlossLatticeContract.confidenceKind}"',
      );
    }
    _validateIdentifier(calibrationVersion, 'producer.calibration_version');
    _validateIdentifier(vocabularyVersion, 'producer.vocabulary_version');
  }

  factory GlossLatticeProducer.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const <String>{
      'classifier_id',
      'classifier_version',
      'confidence_kind',
      'calibration_version',
      'vocabulary_version',
    }, 'producer');
    return GlossLatticeProducer(
      classifierId: _expectString(
        json['classifier_id'],
        'producer.classifier_id',
      ),
      classifierVersion: _expectString(
        json['classifier_version'],
        'producer.classifier_version',
      ),
      confidenceKind: _expectString(
        json['confidence_kind'],
        'producer.confidence_kind',
      ),
      calibrationVersion: _expectString(
        json['calibration_version'],
        'producer.calibration_version',
      ),
      vocabularyVersion: _expectString(
        json['vocabulary_version'],
        'producer.vocabulary_version',
      ),
    );
  }

  final String classifierId;
  final String classifierVersion;
  final String confidenceKind;
  final String calibrationVersion;
  final String vocabularyVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'classifier_id': classifierId,
    'classifier_version': classifierVersion,
    'confidence_kind': confidenceKind,
    'calibration_version': calibrationVersion,
    'vocabulary_version': vocabularyVersion,
  };
}

/// One ranked, calibrated, closed-vocabulary classifier hypothesis.
final class GlossCandidate {
  GlossCandidate({
    required this.glossId,
    required this.rank,
    required this.confidence,
  }) {
    _validateIdentifier(glossId, 'candidate.gloss_id');
    if (rank < 1 || rank > GlossLatticeContract.maxCandidatesPerSlot) {
      _invalid(
        'candidate.rank must be between 1 and '
        '${GlossLatticeContract.maxCandidatesPerSlot}',
      );
    }
    _validateConfidence(confidence, 'candidate.confidence');
  }

  factory GlossCandidate.fromJson(
    Map<String, dynamic> json, {
    String path = 'candidate',
  }) {
    _expectExactKeys(json, const <String>{
      'gloss_id',
      'rank',
      'confidence',
    }, path);
    return GlossCandidate(
      glossId: _expectString(json['gloss_id'], '$path.gloss_id'),
      rank: _expectInt(json['rank'], '$path.rank'),
      confidence: _expectNumber(json['confidence'], '$path.confidence'),
    );
  }

  final String glossId;
  final int rank;
  final double confidence;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'gloss_id': glossId,
    'rank': rank,
    'confidence': confidence,
  };
}

/// One ordered, non-overlapping temporal position in a gloss lattice.
final class GlossSlot {
  GlossSlot({
    required this.slotIndex,
    required this.slotId,
    required this.startMs,
    required this.endMs,
    required List<GlossCandidate> candidates,
    required this.resolvedGlossId,
    required this.provenance,
  }) : candidates = List<GlossCandidate>.unmodifiable(candidates) {
    _validateSafeInteger(slotIndex, 'slot.slot_index');
    if (slotIndex >= GlossLatticeContract.maxSlots) {
      _invalid(
        'slot.slot_index must be less than '
        '${GlossLatticeContract.maxSlots}',
      );
    }
    _validateIdentifier(slotId, 'slot.slot_id');
    _validateSafeInteger(startMs, 'slot.start_ms');
    _validateSafeInteger(endMs, 'slot.end_ms');
    if (endMs <= startMs) {
      _invalid('slot.end_ms must be greater than slot.start_ms');
    }
    if (this.candidates.length > GlossLatticeContract.maxCandidatesPerSlot) {
      _invalid(
        'slot.candidates cannot contain more than '
        '${GlossLatticeContract.maxCandidatesPerSlot} entries',
      );
    }
    if (resolvedGlossId != null) {
      _validateIdentifier(resolvedGlossId!, 'slot.resolved_gloss_id');
    }
    _validateCandidates();
    _validateResolution();
  }

  factory GlossSlot.fromJson(
    Map<String, dynamic> json, {
    String path = 'slot',
  }) {
    _expectExactKeys(json, const <String>{
      'slot_index',
      'slot_id',
      'start_ms',
      'end_ms',
      'candidates',
      'resolved_gloss_id',
      'provenance',
    }, path);
    final rawCandidates = _expectList(json['candidates'], '$path.candidates');
    final candidates = <GlossCandidate>[
      for (var index = 0; index < rawCandidates.length; index += 1)
        GlossCandidate.fromJson(
          _expectObject(rawCandidates[index], '$path.candidates[$index]'),
          path: '$path.candidates[$index]',
        ),
    ];
    final resolved = json['resolved_gloss_id'];
    if (resolved != null && resolved is! String) {
      _invalid('$path.resolved_gloss_id must be a string or null');
    }
    return GlossSlot(
      slotIndex: _expectInt(json['slot_index'], '$path.slot_index'),
      slotId: _expectString(json['slot_id'], '$path.slot_id'),
      startMs: _expectInt(json['start_ms'], '$path.start_ms'),
      endMs: _expectInt(json['end_ms'], '$path.end_ms'),
      candidates: candidates,
      resolvedGlossId: resolved as String?,
      provenance: GlossProvenance.fromWireValue(
        _expectString(json['provenance'], '$path.provenance'),
      ),
    );
  }

  final int slotIndex;
  final String slotId;
  final int startMs;
  final int endMs;
  final List<GlossCandidate> candidates;
  final String? resolvedGlossId;
  final GlossProvenance provenance;

  void _validateCandidates() {
    final glossIds = <String>{};
    for (var index = 0; index < candidates.length; index += 1) {
      final candidate = candidates[index];
      final expectedRank = index + 1;
      if (candidate.rank != expectedRank) {
        _invalid(
          'slot.candidates ranks must be contiguous and start at 1; '
          'expected $expectedRank at index $index',
        );
      }
      if (!glossIds.add(candidate.glossId)) {
        _invalid(
          'slot.candidates gloss_id values must be unique; duplicate '
          '"${candidate.glossId}"',
        );
      }
      if (index > 0 &&
          candidates[index - 1].confidence < candidate.confidence) {
        _invalid(
          'slot.candidates must be ordered by non-increasing confidence',
        );
      }
    }
  }

  void _validateResolution() {
    switch (provenance) {
      case GlossProvenance.classifierHighConfidence:
        if (candidates.isEmpty) {
          _invalid(
            'classifier_high_confidence requires at least one candidate',
          );
        }
        if (resolvedGlossId != candidates.first.glossId) {
          _invalid(
            'classifier_high_confidence resolved_gloss_id must equal the '
            'rank-1 gloss_id',
          );
        }
      case GlossProvenance.topKSignerConfirmed:
        if (resolvedGlossId == null) {
          _invalid('top_k_signer_confirmed requires resolved_gloss_id');
        }
        if (!candidates.any(
          (candidate) => candidate.glossId == resolvedGlossId,
        )) {
          _invalid(
            'top_k_signer_confirmed resolved_gloss_id must identify a '
            'retained candidate',
          );
        }
      case GlossProvenance.fingerspelled:
        if (resolvedGlossId == null) {
          _invalid('fingerspelled requires resolved_gloss_id');
        }
      case GlossProvenance.unresolved:
        if (resolvedGlossId != null) {
          _invalid('unresolved slots must have a null resolved_gloss_id');
        }
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'slot_index': slotIndex,
    'slot_id': slotId,
    'start_ms': startMs,
    'end_ms': endMs,
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
    // This key is required by CTR even when its value is null.
    'resolved_gloss_id': resolvedGlossId,
    'provenance': provenance.wireValue,
  };
}

/// The complete compact object sent as one WebSocket text message.
final class GlossLattice {
  GlossLattice({
    required this.sessionId,
    required this.latticeSeq,
    required this.utteranceId,
    required this.language,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.producer,
    required List<GlossSlot> slots,
    this.type = GlossLatticeContract.type,
    this.schemaVersion = GlossLatticeContract.schemaVersion,
    this.timebase = GlossLatticeContract.timebase,
  }) : slots = List<GlossSlot>.unmodifiable(slots) {
    if (type != GlossLatticeContract.type) {
      _invalid('type must be "${GlossLatticeContract.type}"');
    }
    if (schemaVersion != GlossLatticeContract.schemaVersion) {
      _invalid(
        'schema_version must be "${GlossLatticeContract.schemaVersion}"',
      );
    }
    if (!GlossLatticeContract.isValidUuid(sessionId)) {
      _invalid('session_id must be a canonical UUID string');
    }
    _validateSafeInteger(latticeSeq, 'lattice_seq');
    _validateIdentifier(utteranceId, 'utterance_id');
    if (timebase != GlossLatticeContract.timebase) {
      _invalid('timebase must be "${GlossLatticeContract.timebase}"');
    }
    _validateSafeInteger(startedAtMs, 'started_at_ms');
    _validateSafeInteger(endedAtMs, 'ended_at_ms');
    if (endedAtMs <= startedAtMs) {
      _invalid('ended_at_ms must be greater than started_at_ms');
    }
    if (this.slots.isEmpty ||
        this.slots.length > GlossLatticeContract.maxSlots) {
      _invalid(
        'slots must contain between 1 and '
        '${GlossLatticeContract.maxSlots} entries',
      );
    }
    _validateSlots();
    _validateCompactSize();
  }

  factory GlossLattice.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const <String>{
      'type',
      'schema_version',
      'session_id',
      'lattice_seq',
      'utterance_id',
      'language',
      'timebase',
      'started_at_ms',
      'ended_at_ms',
      'producer',
      'slots',
    }, 'GlossLattice');
    final rawSlots = _expectList(json['slots'], 'slots');
    return GlossLattice(
      type: _expectString(json['type'], 'type'),
      schemaVersion: _expectString(json['schema_version'], 'schema_version'),
      sessionId: _expectString(json['session_id'], 'session_id'),
      latticeSeq: _expectInt(json['lattice_seq'], 'lattice_seq'),
      utteranceId: _expectString(json['utterance_id'], 'utterance_id'),
      language: GlossLatticeLanguage.fromWireValue(
        _expectString(json['language'], 'language'),
      ),
      timebase: _expectString(json['timebase'], 'timebase'),
      startedAtMs: _expectInt(json['started_at_ms'], 'started_at_ms'),
      endedAtMs: _expectInt(json['ended_at_ms'], 'ended_at_ms'),
      producer: GlossLatticeProducer.fromJson(
        _expectObject(json['producer'], 'producer'),
      ),
      slots: <GlossSlot>[
        for (var index = 0; index < rawSlots.length; index += 1)
          GlossSlot.fromJson(
            _expectObject(rawSlots[index], 'slots[$index]'),
            path: 'slots[$index]',
          ),
      ],
    );
  }

  factory GlossLattice.fromWireJson(String source) {
    final byteLength = utf8.encode(source).length;
    if (byteLength > GlossLatticeContract.maxMessageBytes) {
      _invalid(
        'GlossLattice message is $byteLength bytes; maximum is '
        '${GlossLatticeContract.maxMessageBytes}',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      _invalid('GlossLattice is not valid JSON: ${error.message}');
    }
    return GlossLattice.fromJson(_expectObject(decoded, 'GlossLattice'));
  }

  final String type;
  final String schemaVersion;
  final String sessionId;
  final int latticeSeq;
  final String utteranceId;
  final GlossLatticeLanguage language;
  final String timebase;
  final int startedAtMs;
  final int endedAtMs;
  final GlossLatticeProducer producer;
  final List<GlossSlot> slots;

  void _validateSlots() {
    final slotIds = <String>{};
    int? previousEndMs;
    for (var index = 0; index < slots.length; index += 1) {
      final slot = slots[index];
      if (slot.slotIndex != index) {
        _invalid(
          'slot_index values must be contiguous and match array order; '
          'expected $index but found ${slot.slotIndex}',
        );
      }
      if (!slotIds.add(slot.slotId)) {
        _invalid('slot_id values must be unique; duplicate "${slot.slotId}"');
      }
      if (slot.startMs < startedAtMs || slot.endMs > endedAtMs) {
        _invalid(
          'slot "${slot.slotId}" must lie inside the utterance interval',
        );
      }
      if (previousEndMs != null && slot.startMs < previousEndMs) {
        _invalid('slot intervals must be chronological and non-overlapping');
      }
      previousEndMs = slot.endMs;
    }
  }

  void _validateCompactSize() {
    final byteLength = utf8.encode(jsonEncode(toJson())).length;
    if (byteLength > GlossLatticeContract.maxMessageBytes) {
      _invalid(
        'compact GlossLattice is $byteLength bytes; maximum is '
        '${GlossLatticeContract.maxMessageBytes}',
      );
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'schema_version': schemaVersion,
    'session_id': sessionId,
    'lattice_seq': latticeSeq,
    'utterance_id': utteranceId,
    'language': language.wireValue,
    'timebase': timebase,
    'started_at_ms': startedAtMs,
    'ended_at_ms': endedAtMs,
    'producer': producer.toJson(),
    'slots': slots.map((slot) => slot.toJson()).toList(),
  };

  /// Returns the exact compact UTF-8 text payload accepted by the backend.
  String toWireJson() {
    final encoded = jsonEncode(toJson());
    final byteLength = utf8.encode(encoded).length;
    if (byteLength > GlossLatticeContract.maxMessageBytes) {
      _invalid(
        'compact GlossLattice is $byteLength bytes; maximum is '
        '${GlossLatticeContract.maxMessageBytes}',
      );
    }
    return encoded;
  }
}

Never _invalid(String message) =>
    throw GlossLatticeValidationException(message);

void _validateIdentifier(String value, String path) {
  if (!GlossLatticeContract.isValidIdentifier(value)) {
    _invalid(
      '$path must be 1-128 ASCII characters, begin with a letter or digit, '
      'and contain only letters, digits, underscore, dot, colon, or hyphen',
    );
  }
}

void _validateConfidence(double value, String path) {
  if (!value.isFinite || value < 0 || value > 1) {
    _invalid('$path must be a finite number between 0 and 1 inclusive');
  }
}

void _validateSafeInteger(int value, String path) {
  if (value < 0 || value > GlossLatticeContract.maxSafeJsonInteger) {
    _invalid(
      '$path must be between 0 and '
      '${GlossLatticeContract.maxSafeJsonInteger} inclusive',
    );
  }
}

void _expectExactKeys(
  Map<String, dynamic> json,
  Set<String> expected,
  String path,
) {
  final actual = json.keys.toSet();
  final missing = expected.difference(actual);
  final extra = actual.difference(expected);
  if (missing.isNotEmpty) {
    final names = missing.toList()..sort();
    _invalid('$path is missing required properties: ${names.join(', ')}');
  }
  if (extra.isNotEmpty) {
    final names = extra.toList()..sort();
    _invalid('$path contains unknown properties: ${names.join(', ')}');
  }
}

Map<String, dynamic> _expectObject(Object? value, String path) {
  if (value is! Map) {
    _invalid('$path must be a JSON object');
  }
  if (value.keys.any((key) => key is! String)) {
    _invalid('$path must contain only string property names');
  }
  return Map<String, dynamic>.from(value);
}

List<dynamic> _expectList(Object? value, String path) {
  if (value is! List) {
    _invalid('$path must be a JSON array');
  }
  return List<dynamic>.from(value);
}

String _expectString(Object? value, String path) {
  if (value is! String) {
    _invalid('$path must be a string');
  }
  return value;
}

int _expectInt(Object? value, String path) {
  if (value is! int) {
    _invalid('$path must be an integer');
  }
  return value;
}

double _expectNumber(Object? value, String path) {
  if (value is! num) {
    _invalid('$path must be a number');
  }
  final result = value.toDouble();
  if (!result.isFinite) {
    _invalid('$path must be finite');
  }
  return result;
}
