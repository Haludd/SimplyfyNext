# Signed-word sentence pipeline troubleshooting

The room backend returns a signed message in two stages. The HTTP request accepts the words and
returns `202`; the room event channel then sends a `message_upsert` with `processing`, followed by
one terminal `message_upsert` containing either an accepted sentence or a typed repair reason. The
frontend also fetches an authenticated snapshot after a signed submission at 3, 10, 30, and 60
seconds if it has not observed the terminal event, so one missed WebSocket event cannot leave the
message permanently stuck.

## Check the active sentence mode

```bash
curl http://127.0.0.1:8000/readyz
```

Inspect `rooms`:

- `word_provider: disabled` means signed input can only return `policy_unconfigured` repair.
- `word_provider: templates` is the no-network development check for five exact example phrases.
- `word_provider: bedrock`, `anthropic`, or `gemini` identifies the selected hosted model.
- `sentence_acceptance_ready: false` means the policy or sentence provider is missing.

The UI's transport inspector should show an HTTP `202`, then WebSocket `processing`, then
`accepted` or `repair`. A repair is a completed backend response; its `reason_code` identifies the
gate that rejected the input. If the WebSocket event is absent, the later `GET /v1/rooms/{code}`
trace should recover the terminal message.

## Interpret `unsupported_detail`

`unsupported_detail` is later than vocabulary, score, and ambiguity admission. It means the proposed
sentence introduced meaning that the current primary words did not license. The deterministic gate
uses it when a draft:

- adds question force without a current `WHO`, `WHAT`, `WHERE`, `WHEN`, `WHY`, `HOW`, or `QUESTION`;
- changes a lexical word beyond the small reviewed inflection list;
- inserts a token other than the permitted articles `a/an/the` or present auxiliaries `am/is/are`;
- attaches an inserted article or auxiliary to a source index instead of marking it as an insertion.

The critic can also return it for an invented subject, name, number, negation, tense, quantity, or
other claim. Low score, a close alternative, an unknown word, an unnatural fragment, and a context
conflict have separate reason codes and should not be reported as `unsupported_detail`.

`WHERE` + `FOOD` is a supported sequence. Both `Where is food?` and `Where is the food?` are grounded:
`WHERE` and `FOOD` align lexically, while `is` and optional `the` use empty source indices. The
configured score and alternative-margin policy owns confidence admission; an assembler or critic
must not reject an already admitted word solely because its numeric score looks low.

For a repeatable diagnosis, use **Preview JSON** before **Send sentence** and test a synthetic copy of
its `words` array. Record the deployed commit, `/readyz` provider, terminal `reason_code`, and
`target_indices`. Conversation content should not be added to server logs or retained as release
evidence.

## Prove backend-to-frontend delivery without API credits

Start the backend with the exact local templates:

```bash
cd ~/hackathons/SimplyNext
source .venv-integration/bin/activate
SIMPLYNEXT_ENVIRONMENT=development \
SIMPLYNEXT_HOST=127.0.0.1 \
SIMPLYNEXT_ALLOWED_HOSTS=127.0.0.1,localhost \
SIMPLYNEXT_ALLOWED_ORIGINS=http://localhost:8081 \
SIMPLYNEXT_BEDROCK_ENABLED=false \
SIMPLYNEXT_ANTHROPIC_ENABLED=false \
SIMPLYNEXT_GEMINI_ENABLED=false \
SIMPLYNEXT_WORD_POLICY_PATH=data/word_policy.synthetic.json \
SIMPLYNEXT_WORD_TEMPLATES_PATH=data/word_templates.example.json \
python main.py
```

In a second terminal:

```bash
cd ~/hackathons/SimplyNext
source .venv-integration/bin/activate
python scripts/room_protocol_smoke.py \
  --base-url http://127.0.0.1:8000 \
  --templates
```

This sends `HELLO` and verifies that both room participants receive `Hello.`. The other exact demo
sequences are `WATER I WANT`, `I WANT WATER`, `I CLEAN TABLE`, and `PLEASE HELP`. Arbitrary words
need one hosted provider because templates do not synthesize new sentences.

## Bedrock mode

The current default is the global Claude Haiku 4.5 inference profile in `ap-southeast-1`. Set:

```dotenv
SIMPLYNEXT_BEDROCK_ENABLED=true
SIMPLYNEXT_ANTHROPIC_ENABLED=false
SIMPLYNEXT_GEMINI_ENABLED=false
SIMPLYNEXT_BEDROCK_LEASE_OWNER=YOUR_TEAM_OWNER
SIMPLYNEXT_WORD_POLICY_PATH=data/word_policy.json
```

The AWS identity must be allowed to call `bedrock:GetInferenceProfile` and `bedrock:InvokeModel` for
the inference profile and its underlying regional/global foundation-model resources. Startup does a
control-plane check and one small, cost-accounted runtime call. If either fails, the backend must not
be treated as sentence-ready. See AWS's
[inference prerequisites](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-prereq.html)
and [global inference IAM requirements](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html).

The AWS identity checked during this troubleshooting session was denied
`bedrock:GetInferenceProfile`; that prevents the current Bedrock backend from starting in provider
mode. Fix the IAM policy/model access first, then restart and confirm `/readyz` reports `bedrock` and
`sentence_acceptance_ready: true`.

## Temporary Gemini diagnostic

Gemini runs through the same assembler, critic, context, grounding, cost guard, room commit, and
frontend delivery code. It changes only the provider adapter, which makes it useful for separating
an AWS permission/model problem from an application problem.

Create a server-side Gemini API key and put these values in the ignored `.env` file:

```dotenv
GEMINI_API_KEY=YOUR_KEY
SIMPLYNEXT_GEMINI_ENABLED=true
SIMPLYNEXT_BEDROCK_ENABLED=false
SIMPLYNEXT_ANTHROPIC_ENABLED=false
SIMPLYNEXT_GEMINI_MODEL_ID=gemini-3.1-flash-lite
SIMPLYNEXT_GEMINI_LEASE_OWNER=YOUR_TEAM_OWNER
SIMPLYNEXT_GEMINI_INPUT_USD_PER_MILLION_TOKENS=0
SIMPLYNEXT_GEMINI_OUTPUT_USD_PER_MILLION_TOKENS=0
SIMPLYNEXT_GEMINI_CACHE_WRITE_USD_PER_MILLION_TOKENS=0
SIMPLYNEXT_GEMINI_CACHE_READ_USD_PER_MILLION_TOKENS=0
SIMPLYNEXT_WORD_POLICY_PATH=data/word_policy.json
```

Keep the API key in the backend only. The free tier has project/model quotas and Google states that
free-tier inputs and outputs may be used to improve its products. Recheck pricing and terms before
testing in the official [pricing](https://ai.google.dev/gemini-api/docs/pricing) and
[rate-limit](https://ai.google.dev/gemini-api/docs/rate-limits) pages. To isolate provisional
classifier vocabulary or score problems in development, these gates
can temporarily be set false:

```dotenv
SIMPLYNEXT_WORD_POLICY_ENFORCE_VOCABULARY=false
SIMPLYNEXT_WORD_POLICY_ENFORCE_SCORES=false
```

Production rejects either relaxation and also rejects the checked-in synthetic policies. A public
release still needs the reviewed producer policy/evaluation described in
`plan/WORD_ACCEPTANCE_POLICY.md`.
