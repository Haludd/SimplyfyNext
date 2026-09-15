import 'dart:convert';

enum RoomRole { signer, hearing }

enum RoomConnectionStatus {
  idle,
  creating,
  joining,
  connecting,
  connected,
  reconnecting,
  ended,
  error,
}

final class RoomCredentials {
  const RoomCredentials({
    required this.code,
    required this.participantId,
    required this.role,
    required this.token,
    required this.joinPath,
  });

  factory RoomCredentials.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const <String>{
      'event_schema_version',
      'utterance_schema_version',
      'code',
      'participant_id',
      'role',
      'token',
      'join_path',
    });
    if (json['event_schema_version'] != '1.0' ||
        json['utterance_schema_version'] != '1.0') {
      throw const FormatException('Unsupported room schema version');
    }
    final role = switch (json['role']) {
      'signer' => RoomRole.signer,
      'hearing' => RoomRole.hearing,
      _ => throw const FormatException('Unsupported participant role'),
    };
    final code = _string(json, 'code');
    if (!RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$').hasMatch(code)) {
      throw const FormatException('Invalid room code');
    }
    return RoomCredentials(
      code: code,
      participantId: _string(json, 'participant_id'),
      role: role,
      token: _string(json, 'token'),
      joinPath: _string(json, 'join_path'),
    );
  }

  final String code;
  final String participantId;
  final RoomRole role;
  final String token;
  final String joinPath;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'event_schema_version': '1.0',
    'utterance_schema_version': '1.0',
    'code': code,
    'participant_id': participantId,
    'role': role.name,
    'token': token,
    'join_path': joinPath,
  };
}

final class RoomParticipant {
  const RoomParticipant({
    required this.id,
    required this.role,
    required this.alias,
    required this.online,
  });

  factory RoomParticipant.fromJson(Map<String, dynamic> json) =>
      RoomParticipant(
        id: _string(json, 'participant_id'),
        role: switch (json['role']) {
          'signer' => RoomRole.signer,
          'hearing' => RoomRole.hearing,
          _ => throw const FormatException('Unsupported participant role'),
        },
        alias: _string(json, 'alias'),
        online: _boolean(json, 'online'),
      );

  final String id;
  final RoomRole role;
  final String alias;
  final bool online;

  RoomParticipant copyWith({bool? online}) => RoomParticipant(
    id: id,
    role: role,
    alias: alias,
    online: online ?? this.online,
  );
}

final class RoomRepair {
  const RoomRepair({
    required this.action,
    required this.prompt,
    required this.reasonCode,
    required this.targetIndices,
  });

  factory RoomRepair.fromJson(Map<String, dynamic> json) => RoomRepair(
    action: _string(json, 'action'),
    prompt: _string(json, 'prompt'),
    reasonCode: _string(json, 'reason_code'),
    targetIndices:
        (json['target_indices'] as List<dynamic>? ?? const <dynamic>[])
            .map((value) => value as int)
            .toList(growable: false),
  );

  final String action;
  final String prompt;
  final String reasonCode;
  final List<int> targetIndices;
}

final class RoomMessage {
  const RoomMessage({
    required this.messageId,
    required this.senderId,
    required this.clientSequence,
    required this.serverSequence,
    required this.contextVersion,
    required this.source,
    required this.status,
    this.text,
    this.ttsText,
    this.repair,
  });

  factory RoomMessage.fromJson(Map<String, dynamic> json) {
    final translation = json['translation'];
    return RoomMessage(
      messageId: _string(json, 'message_id'),
      senderId: _string(json, 'sender_id'),
      clientSequence: _integer(json, 'client_sequence'),
      serverSequence: _integer(json, 'server_sequence'),
      contextVersion: _integer(json, 'context_version'),
      source: _string(json, 'source'),
      status: _string(json, 'status'),
      text: json['text'] as String?,
      ttsText: translation is Map
          ? Map<String, dynamic>.from(translation)['tts_text'] as String?
          : null,
      repair: json['repair'] is Map
          ? RoomRepair.fromJson(
              Map<String, dynamic>.from(json['repair'] as Map),
            )
          : null,
    );
  }

  final String messageId;
  final String senderId;
  final int clientSequence;
  final int serverSequence;
  final int contextVersion;
  final String source;
  final String status;
  final String? text;
  final String? ttsText;
  final RoomRepair? repair;

  String get key => '$senderId:$messageId';
  bool get isTerminal => status == 'accepted' || status == 'repair';
}

Map<String, dynamic> decodeRoomObject(String source) {
  final value = jsonDecode(source);
  if (value is! Map) throw const FormatException('Expected a JSON object');
  return Map<String, dynamic>.from(value);
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid $key');
  }
  return value;
}

int _integer(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

bool _boolean(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key');
  return value;
}

void _requireKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unsupported response shape');
  }
}
