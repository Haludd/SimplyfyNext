# SimplyNext contracts

The only translation ingress is frozen `TranslatedSignUtterance v1`, ASL → English, under
`POST /v1/rooms/{code}/sign-utterances`. The normative schema is the root
`TRANSLATED_SIGN_UTTERANCE_V1.md`; packaged schema and strict semantic model live in `contracts/`.
No ingress or event v1 fields changed in the context/policy/cutover round.

See [WORD_ROOM_V1.md](WORD_ROOM_V1.md) for complete HTTP/WebSocket semantics and generated client
handoff. The event union keeps accepted/processing/repair disjoint; repairs contain no speculative
sentence or TTS. Signed 202 means admitted, not accepted translation. Retry the same message ID,
sequence and semantic payload after a lost acknowledgement; terminal state is recovered through
snapshot or upserts. Repair continuation uses a new ID and next sequence or typed text.

Internal draft/verdict/evaluation schemas are not client inputs. The critic now explicitly reports
standalone coherence and history relation; this does not change the frozen frontend protocol.

The old `/v1/sessions` and streaming endpoints are absent and return 404/reject WebSocket upgrades.
There is no compatibility translation of old payloads. Unsupported source languages fail startup
or strict ingress negotiation. Backend fixture checks pass independently of the frontend; recorded
frontend execution and owner sign-off remain external evidence.
