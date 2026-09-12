const deepFaceEmotionLabels = <String>[
  'angry',
  'disgust',
  'fear',
  'happy',
  'sad',
  'surprise',
  'neutral',
];

class FaceLandmark {
  const FaceLandmark({
    required this.index,
    required this.x,
    required this.y,
    required this.z,
    this.name,
    this.visibility = 1,
  });

  final int index;
  final double x;
  final double y;
  final double z;
  final String? name;
  final double visibility;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'x': x,
    'y': y,
    'z': z,
    if (name != null) 'name': name,
    'visibility': visibility,
  };

  factory FaceLandmark.fromJson(Map<String, dynamic> json) => FaceLandmark(
    index: (json['index'] as num?)?.toInt() ?? 0,
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    z: (json['z'] as num?)?.toDouble() ?? 0,
    name: json['name'] as String?,
    visibility: (json['visibility'] as num?)?.toDouble() ?? 1,
  );
}

class FaceExpressionFeatures {
  const FaceExpressionFeatures({
    required this.confidence,
    required this.label,
    required this.landmarks,
    required this.emotionScores,
    this.source = 'deepface',
  });

  final double confidence;
  final String label;
  final List<FaceLandmark> landmarks;
  final Map<String, double> emotionScores;
  final String source;

  bool get isVisible =>
      confidence > 0 && (landmarks.isNotEmpty || emotionScores.isNotEmpty);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'confidence': confidence,
    'label': label,
    'landmarks': landmarks.map((landmark) => landmark.toJson()).toList(),
    'emotion_scores': emotionScores,
    'source': source,
  };

  factory FaceExpressionFeatures.fromJson(Map<String, dynamic> json) {
    final rawEmotionScores = json['emotion_scores'] as Map<dynamic, dynamic>?;
    final emotionScores = <String, double>{};
    rawEmotionScores?.forEach((key, value) {
      if (value is num) emotionScores[key.toString()] = value.toDouble();
    });
    return FaceExpressionFeatures(
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? 'not detected',
      landmarks: (json['landmarks'] as List<dynamic>? ?? <dynamic>[])
          .map((value) => FaceLandmark.fromJson(value as Map<String, dynamic>))
          .toList(growable: false),
      emotionScores: emotionScores,
      source: json['source'] as String? ?? 'deepface',
    );
  }
}
