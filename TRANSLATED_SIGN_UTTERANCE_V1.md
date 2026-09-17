# TranslatedSignUtterance v1

This is the frozen frontend-to-backend contract for one explicitly committed
ASL utterance. Camera frames, landmarks, feature vectors, audio, participant
credentials, and conversation history are excluded. The backend accepts the
canonical JSON object below at the room sign endpoint. The following JSON
Schema is normative for version 1.0.

The producer object accepts three exact local profiles: the built-in PopSign
model, personal landmark templates, and a combined profile for an utterance
that contains words from both recognizers. Personal landmark templates stay
on the device; only their validated English word and confidence are sent.

## Canonical message

```json
{
  "type": "translated_sign_utterance",
  "schema_version": "1.0",
  "message_id": "1f205ca5-6eb6-42f1-a490-811f612fbb98",
  "client_sequence": 0,
  "source_language": "asl",
  "target_language": "en",
  "is_final": true,
  "completion_reason": "user_commit",
  "producer": {
    "recognizer_id": "signchat_asl_signs_onnx",
    "recognizer_version": "signchat_asl_signs_onnx",
    "translator_id": "asl_label_to_english",
    "translator_version": "1.0.0",
    "vocabulary_version": "popsign_250_en_v1",
    "confidence_kind": "normalized_model_score"
  },
  "words": [
    {
      "index": 0,
      "token_id": "word-0",
      "word": "TABLE",
      "confidence": 0.6780357956886292,
      "alternatives": [
        {
          "rank": 2,
          "word": "CLEAN",
          "confidence": 0.06273823976516724
        },
        {
          "rank": 3,
          "word": "ON",
          "confidence": 0.0337180569767952
        }
      ]
    },
    {
      "index": 1,
      "token_id": "word-1",
      "word": "TABLE",
      "confidence": 0.6013476848602295,
      "alternatives": [
        {
          "rank": 2,
          "word": "CLEAN",
          "confidence": 0.15389969944953918
        },
        {
          "rank": 3,
          "word": "ON",
          "confidence": 0.04783957079052925
        }
      ]
    }
  ]
}
```
## JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://signbridge.example/schemas/translated-sign-utterance-v1.json",
  "title": "TranslatedSignUtteranceV1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "type",
    "schema_version",
    "message_id",
    "client_sequence",
    "source_language",
    "target_language",
    "is_final",
    "completion_reason",
    "producer",
    "words"
  ],
  "properties": {
    "type": {
      "const": "translated_sign_utterance"
    },
    "schema_version": {
      "const": "1.0"
    },
    "message_id": {
      "type": "string",
      "format": "uuid"
    },
    "client_sequence": {
      "type": "integer",
      "minimum": 0,
      "maximum": 9007199254740991
    },
    "source_language": {
      "const": "asl"
    },
    "target_language": {
      "const": "en"
    },
    "is_final": {
      "const": true
    },
    "completion_reason": {
      "const": "user_commit"
    },
    "producer": {
      "$ref": "#/$defs/producer"
    },
    "words": {
      "type": "array",
      "minItems": 1,
      "maxItems": 64,
      "items": {
        "$ref": "#/$defs/wordToken"
      }
    }
  },
  "$defs": {
    "identifier": {
      "type": "string",
      "minLength": 1,
      "maxLength": 80,
      "pattern": "^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$"
    },
    "englishWord": {
      "type": "string",
      "minLength": 1,
      "maxLength": 80,
      "pattern": "^[A-Z0-9]+(?:['-][A-Z0-9]+)*$"
    },
    "score": {
      "type": "number",
      "minimum": 0,
      "maximum": 1
    },
    "producer": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "recognizer_id",
        "recognizer_version",
        "translator_id",
        "translator_version",
        "vocabulary_version",
        "confidence_kind"
      ],
      "properties": {
        "recognizer_id": {
          "enum": [
            "signchat_asl_signs_onnx",
            "personal_landmark_templates",
            "signbridge_local_recognizers"
          ]
        },
        "recognizer_version": {
          "enum": [
            "signchat_asl_signs_onnx",
            "personal_landmark_templates_v1",
            "signbridge_local_recognizers_v1"
          ]
        },
        "translator_id": {
          "const": "asl_label_to_english"
        },
        "translator_version": {
          "const": "1.0.0"
        },
        "vocabulary_version": {
          "enum": [
            "popsign_250_en_v1",
            "personal_signs_local_v1",
            "popsign_250_plus_personal_v1"
          ]
        },
        "confidence_kind": {
          "const": "normalized_model_score"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "recognizer_id": {
                "const": "signchat_asl_signs_onnx"
              }
            }
          },
          "then": {
            "properties": {
              "recognizer_version": {
                "const": "signchat_asl_signs_onnx"
              },
              "vocabulary_version": {
                "const": "popsign_250_en_v1"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "recognizer_id": {
                "const": "personal_landmark_templates"
              }
            }
          },
          "then": {
            "properties": {
              "recognizer_version": {
                "const": "personal_landmark_templates_v1"
              },
              "vocabulary_version": {
                "const": "personal_signs_local_v1"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "recognizer_id": {
                "const": "signbridge_local_recognizers"
              }
            }
          },
          "then": {
            "properties": {
              "recognizer_version": {
                "const": "signbridge_local_recognizers_v1"
              },
              "vocabulary_version": {
                "const": "popsign_250_plus_personal_v1"
              }
            }
          }
        }
      ]
    },
    "alternative": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "rank",
        "word",
        "confidence"
      ],
      "properties": {
        "rank": {
          "type": "integer",
          "minimum": 2,
          "maximum": 5
        },
        "word": {
          "$ref": "#/$defs/englishWord"
        },
        "confidence": {
          "$ref": "#/$defs/score"
        }
      }
    },
    "wordToken": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "index",
        "token_id",
        "word",
        "confidence",
        "alternatives"
      ],
      "properties": {
        "index": {
          "type": "integer",
          "minimum": 0,
          "maximum": 63
        },
        "token_id": {
          "$ref": "#/$defs/identifier"
        },
        "word": {
          "$ref": "#/$defs/englishWord"
        },
        "confidence": {
          "$ref": "#/$defs/score"
        },
        "alternatives": {
          "type": "array",
          "minItems": 0,
          "maxItems": 4,
          "items": {
            "$ref": "#/$defs/alternative"
          }
        }
      }
    }
  }
}
```
