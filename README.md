**SIMPLYNEXT**





# METADATA
<details>
<summary>Document code, status, review date, and usage instructions.</summary>

| Field                   | Value                                         |
| :---------------------- | :-------------------------------------------- |
| **Code**                | `RDM`                                         |
| **Status**              | Live                                          |
| **Last reviewed**       | 2026-09-13                                    |
| **Source of truth for** | Onboarding, environment setup, project status |
| **Related**             | [`RIX`](ref_index.md) · [`CLD`](CLAUDE.md)    |

**Summary.** Real-time sign-language translation from ordinary camera video, with no gloves and no
wearables. Built for the SimplifyNext Agentic AI Hackathon 2026.

**For the team.** This is the human entry point. [`RIX`](ref_index.md) records where every document
lives and how to cite any section of it; read it before this file. Sections
[`RDM_S3`](#3-product-summary), [`RDM_S6`](#6-environment-and-installation) and
[`RDM_S7`](#7-aws-setup) carry placeholders marking unfinished work.

**For the assistant.** This file must let a judge run the code from a clean clone (`D3_p42`).
Update [`RDM_S9`](#9-project-status) whenever a component changes state, and replace each
placeholder as its update trigger fires.

</details>

---





# 1. TABLE OF CONTENTS
1.  [**Table of contents**](#1-table-of-contents) — this table
2.  [**Quick start**](#2-quick-start) — first-session reading order, by role
3.  [**Product summary**](#3-product-summary) — the problem, the product, the design invariant
4.  [**Repository layout**](#4-repository-layout) — directory tree and document codes
5.  [**Reading order**](#5-reading-order) — full onboarding sequence with time estimates
6.  [**Environment and installation**](#6-environment-and-installation) — prerequisites, setup,
    required project structure
7.  [**AWS setup**](#7-aws-setup) — account registration, sandbox lease, budget cap
8.  [**Working conventions**](#8-working-conventions) — document, addressing and git conventions
9.  [**Project status**](#9-project-status) — what exists, what does not, what is blocked
10. [**Glossary**](#10-glossary) — document codes and domain terms
11. [**Credits and sources**](#11-credits-and-sources) — attribution and licensing

---





# 2. QUICK START
## 2.1. First Session
1. **[`RIX`](ref_index.md)** · *Time:* 5 min
   *Focus:* How the repository addresses and formats itself
2. **[`SCR`](plan/scribbles.md)** · *Time:* 3 min
   *Focus:* The product intent, unedited
3. **[`JCR_S1`](plan/JCR_judging_criteria.md#1-the-score-at-a-glance),
   [`JCR_S8`](plan/JCR_judging_criteria.md#8-self-scoring-checklist)** · *Time:* 7 min
   *Focus:* The scoring model and the pre-submission checklist




## 2.2. By Role
1. **Vision pipeline**
   [`MPS`](doc/MPS_mediapipe_synthesis.md) and [`APS`](doc/APS_apple_synthesis.md), then
   [`ARC_S6.5`](plan/ARC_architecture.md#65-perception-engineering-rules) and
   [`ARC_S7.2`](plan/ARC_architecture.md#72-the-four-reference-repositories-compared)
2. **Agent layer**
   [`TRN_S2`](doc/TRN_training_synthesis.md#2-d1--llm-foundations-agents-prompting-bedrock)
   through
   [`TRN_S4`](doc/TRN_training_synthesis.md#4-d3--framing-classes-practices-case-studies),
   then [`ARC_S6`](plan/ARC_architecture.md#6-the-recommended-architecture)
3. **Deck and video**
   [`JCR_S4`](plan/JCR_judging_criteria.md#4-problem-statement),
   [`JCR_S6`](plan/JCR_judging_criteria.md#6-the-10-slide-deck),
   [`JCR_S7`](plan/JCR_judging_criteria.md#7-the-5-minute-demo-video)
4. **Risk and evaluation**
   [`RSK_S10`](plan/RSK_risk_register.md#10-top-ten-risks) — the top ten
5. **AWS ownership**
   [`TRN_S6`](doc/TRN_training_synthesis.md#6-d6--aws-access-and-budget)

Before writing any document or code: [`CLD_S3`](CLAUDE.md#3-document-rules) and
[`CLD_S5`](CLAUDE.md#5-conduct-on-this-project).

---





# 3. PRODUCT SUMMARY
## 3.1. The Problem
A communication barrier persists between people with hearing loss and people without it. Signers
either rely on an interpreter — Singapore's national association lists **2 Deaf and more than 6
hearing staff interpreters**, supported by 55 community interpreters on an ad-hoc basis
[[SADeaf]](https://sadeaf.org.sg/faqconc_cat/sl_interpreter/) — or fall back on typing, which
breaks the flow of conversation.




## 3.2. The Product
SimplyNext reads sign language from an ordinary camera and produces conversational text or audio.
Perception runs locally — subject tracking, landmark extraction, segmentation and recognition — and
an agentic layer on AWS Bedrock assembles, critiques and, **where confidence is low, refuses to
guess and requests a repair instead**.

That last property is the design invariant. For an assistive tool, a fluent wrong sentence
attributed to a deaf person is worse than no sentence at all.

Technical direction and supporting evidence: [`ARC`](plan/ARC_architecture.md).

> **Placeholder — problem statement.**
> **Missing:** the POV problem statement in `D3_p6` format, naming one person at one moment.
> **Update trigger:** the four open questions in
> [`ARC_S9.1`](plan/ARC_architecture.md#91-open-questions-for-the-team)
> are answered, in particular the scenario and the named person.
> **Owner:** team.

---





# 4. REPOSITORY LAYOUT
```text
SimplyNext/
├── README.md               RDM      human entry point
├── ref_index.md            RIX      registry · addressing scheme · formatting rules
├── CLAUDE.md               CLD      rules for AI agents
│
├── plan/                            what the team is building  ← source of truth
│   ├── scribbles.md        SCR      raw ideation, product intent
│   ├── JCR_judging_criteria.md      how the submission is scored
│   ├── ARC_architecture.md          technical direction, sourced
│   └── RSK_risk_register.md         136 catalogued risks
│
├── doc/                             reference material and syntheses
│   ├── [D1..D6]*.pdf                training decks (read-only originals)
│   ├── TRN_training_synthesis.md    all six decks, condensed
│   ├── APS_apple_synthesis.md       Apple HandPose, in short
│   ├── MPS_mediapipe_synthesis.md   MediaPipe, in short  ← the dependency
│   ├── DHS_depthai_synthesis.md     DepthAI hand tracker, in short
│   └── OPS_openpose_synthesis.md    OpenPose, in short  ← and why it was rejected
│
└── ref_repo/                        four third-party clones. THE CLONES ARE GIT-IGNORED
    ├── apple/APR_apple_report.md            tracked — Apple, in full
    ├── google-mediapipe/MPR_mediapipe_report.md      tracked — MediaPipe, in full
    ├── depthai-hand-tracker/DHR_depthai_report.md    tracked — DepthAI, in full
    └── openpose/OPR_openpose_report.md               tracked — OpenPose, in full
```

`src/`, `tests/` and `data/` do not exist yet — see [`RDM_S9`](#9-project-status).

---





# 5. READING ORDER
Full onboarding sequence for someone joining the team cold. Roughly two hours end to end.

1. **[`RIX`](ref_index.md)** · *Time:* 5 min
   *Purpose:* How to find and cite everything else
2. **[`SCR`](plan/scribbles.md)** · *Time:* 3 min
   *Purpose:* The original idea, unedited
3. **[`JCR`](plan/JCR_judging_criteria.md)** · *Time:* 20 min
   *Purpose:* The specification the submission is graded against
4. **[`ARC`](plan/ARC_architecture.md)** · *Time:* 30 min
   *Purpose:* What is being built, and why the obvious approach fails
5. **[`RSK_S10`](plan/RSK_risk_register.md#10-top-ten-risks)** · *Time:* 10 min
   *Purpose:* The ten risks that matter most
6. **[`MPS`](doc/MPS_mediapipe_synthesis.md)** · *Time:* 5 min
   *Purpose:* The perception library the project depends on, and its four traps
7. **[`TRN`](doc/TRN_training_synthesis.md)** · *Time:* 30 min
   *Purpose:* The six training decks, condensed
8. **[`CLD`](CLAUDE.md)** · *Time:* 10 min
   *Purpose:* Working rules

Then the other three repository syntheses, 5 minutes each:
[`APS`](doc/APS_apple_synthesis.md) for the segmentation state machine,
[`DHS`](doc/DHS_depthai_synthesis.md) for the tracking fixes, and
[`OPS`](doc/OPS_openpose_synthesis.md) for the rejected alternative.

Deep dives, as needed: the four full reports in `ref_repo/` —
[`APR`](ref_repo/apple/APR_apple_report.md),
[`MPR`](ref_repo/google-mediapipe/MPR_mediapipe_report.md),
[`DHR`](ref_repo/depthai-hand-tracker/DHR_depthai_report.md),
[`OPR`](ref_repo/openpose/OPR_openpose_report.md) — and the remainder of
[`RSK`](plan/RSK_risk_register.md).

---





# 6. ENVIRONMENT AND INSTALLATION
> **Note:** implementation has not started. This section records the environment the competition
> requires (`D3_p42`, `D3_p23`) so that the first commit lands correctly.




## 6.1. Prerequisites
| Tool                               | Purpose                                        |
| :--------------------------------- | :--------------------------------------------- |
| **Git**                            | Version control — https://git-scm.com/install/ |
| **Python 3.11+**                   | `D3_p42`: *"Python is strongly recommended"*   |
| **`uv`**                           | The package manager used by the training labs  |
| A webcam                           | The entire input modality                      |
| An AWS account with Bedrock access | [`RDM_S7`](#7-aws-setup)                       |

Installing `uv`:

```bash
# Linux / macOS
curl -LsSf https://astral.sh/uv/install.sh | sh

# Windows (PowerShell)
powershell -c "irm https://astral.sh/uv/install.ps1 | iex"
```




## 6.2. Getting the Repository
```bash
git clone <this-repo>
cd SimplyNext
```

**The four reference clones under `ref_repo/` are not in this repository.** `.gitignore` excludes
them and tracks only the four report documents beside them —
[`RIX_S5.2`](ref_index.md#52-what-version-control-tracks). To obtain one, clone it into the
sub-directory the report's provenance section names:

```bash
# MediaPipe    -> ref_repo/google-mediapipe/mediapipe
# DepthAI      -> ref_repo/depthai-hand-tracker/depthai_hand_tracker
# OpenPose     -> ref_repo/openpose/openpose
git clone https://github.com/google-ai-edge/mediapipe.git
git clone https://github.com/geaxgx/depthai_hand_tracker.git
git clone https://github.com/CMU-Perceptual-Computing-Lab/openpose.git
```

None of them is part of the build, and **nothing in `src/` may import from `ref_repo/`**. The
Apple sample is Swift; OpenPose is licensed for non-commercial research only —
[`OPS_S2.1`](doc/OPS_openpose_synthesis.md#21-the-licence).




## 6.3. Training Labs
The hackathon's own exercises live in a separate repository (`D1`), and are worth running before
project code:

```bash
git clone https://github.com/thetsuwin66/agentic_ai_hackathon_2026.git
cd agentic_ai_hackathon_2026/lab
uv sync
uv run 00_check_env.py
```

Session 1 labs need only a free Groq key (`console.groq.com`, rate-limited, not billed). Bedrock is
not used until Session 2.




## 6.4. Project Environment
> **Placeholder — run instructions.**
> **Missing:** the real entry point, dependency manifest and `.env.example` contents. The commands
> below are the intended shape, not a working sequence.
> **Update trigger:** the first commit under `src/`.
> **Owner:** assistant, on the commit that creates `src/`.

```bash
uv sync                       # install dependencies from pyproject/requirements
cp .env.example .env          # then fill in local keys
uv run python -m src.main     # entry point does not exist yet
```

> **Warning:** secrets go in `.env`, which is git-ignored. Never commit a key, and never commit the
> 2FA secret from `D6`.




## 6.5. Required Project Structure
`D3_p23` states that judges expect a legible hierarchy. The first code to land should produce:

```text
src/          implementation; module names must match the architecture slide
docs/         generated or developer documentation
data/         datasets and recordings  (check consent — RSK HUM-15)
tests/        automated tests
requirements.txt  or  pyproject.toml
.env.example      committed;  .env  is not
README.md         must let a judge run the code from a clean clone
```

---





# 7. AWS SETUP
Full walkthrough: [`TRN_S6`](doc/TRN_training_synthesis.md#6-d6--aws-access-and-budget). Original
source: `D6`.




## 7.1. Registration and Lease
1. **One person per team** registers, at `https://d-9667b91afb.awsapps.com/start`.
2. The username is `hackathon2026,<group-leader-email>` — **note the comma, no spaces**.
3. Set up 2FA and **share the secret key** with the team so every member can log in.
4. Applications → *Innovation Sandbox Ignite Hackathon Application* → *Request a new lease* →
   template **Hackathon 2026**.
5. **Approval takes up to 2 working days.** The email usually lands in spam and may be blocked
   entirely; log in periodically to check status rather than waiting for mail.
6. Enable Bedrock model access for **Claude Haiku 4.5** in **`ap-southeast-1`**. Access is granted
   per model *and* per region.




## 7.2. The Budget
> **Warning — this is a kill switch, not a bill.** `D6`: at **US$20** access to the account is
> **revoked**; at **US$30** the account is **terminated**. One lease per group; additional leases
> *"would not be granted"* barring exceptions.

Operating rules, argued in [`ARC_S8`](plan/ARC_architecture.md#8-cost-model-against-the-aws-cap):

- All perception runs locally. Nothing at 30 fps reaches Bedrock.
- The agent is invoked **per utterance**, never per frame.
- Every loop carries a hard iteration cap held in state.
- `inputTokens` and `outputTokens` are logged on every call, from the first commit.
- One named person owns the lease and watches the spend.

SSO sessions expire after 8–12 hours, so each working day starts with
`aws sso login --profile <name>`.

> **Placeholder — lease status.**
> **Missing:** who registered the account, the lease approval date, and the current spend.
> **Update trigger:** confirmation from the registering team member.
> **Owner:** team.

---





# 8. WORKING CONVENTIONS
## 8.1. Documents
Every `.md` file follows [`RIX_S4`](ref_index.md#4-markdown-formatting-rules): a bold title, a
collapsible `# METADATA`
block, `# N. ALL CAPS` sections, `## N.M. Caps Initials Only` sub-sections, graduated blank lines
before each heading, `---` between sections, tables only where a row fits on one line, sources
tagged, and uncertainty marked `⚠`.

Any section is referenced from anywhere by its address:

```text
ARC_S7.1     plan/ARC_architecture.md, section 7.1
RSK_S7.1     plan/RSK_risk_register.md, section 7.1
D3_p39       doc/[D3]_..., slide 39
```




## 8.2. Registering a New Document
1. Pick a free three-letter code that compresses the document's name.
2. Name the file `<CODE>_<snake_case_name>.md`.
3. Add a row to [`RIX_S2.1`](ref_index.md#21-live-documents) **in the same commit**.




## 8.3. Git
- Never commit `.env`, keys, or the `D6` 2FA secret.
- Never commit video of a person without documented consent
  ([`RSK`](plan/RSK_risk_register.md) `HUM-15`).
- Keep the `ref_index.md` update in the same commit as the change it describes.
- Check the 5 GB submission limit before adding data or model weights.

---





# 9. PROJECT STATUS
1.  **Problem definition**
    🟡 Idea is clear; the POV problem statement is **not yet written** —
    [`JCR_S4`](plan/JCR_judging_criteria.md#4-problem-statement)
2.  **Judging criteria**
    🟢 Extracted and checklisted — [`JCR`](plan/JCR_judging_criteria.md)
3.  **Architecture**
    🟡 Proposed with sources; **16 decisions awaiting team sign-off** —
    [`ARC_S9`](plan/ARC_architecture.md#9-decisions)
4.  **Risks**
    🟢 136 catalogued — [`RSK`](plan/RSK_risk_register.md)
5.  **Reference repositories**
    🟢 All four analysed and compared; MediaPipe chosen as the perception layer —
    [`ARC_S7.2`](plan/ARC_architecture.md#72-the-four-reference-repositories-compared)
6.  **Training material**
    🟢 Synthesised — [`TRN`](doc/TRN_training_synthesis.md)
7.  **Master plan (`PLN`)**
    🔴 Not written — blocked on the architecture decisions
8.  **Frontend implementation (`appTesting/`)**
    🟢 Browser-local 250-sign ASL ONNX classifier integrated on 2026-09-13. Setup and
    model details: [`SIGNCHAT_ASL_RECOGNITION`](appTesting/SIGNCHAT_ASL_RECOGNITION.md).
9.  **Dataset**
    🔴 Not collected. The largest open question
10. **AWS lease**
    ⬜ Unconfirmed — see the placeholder in [`RDM_S7.2`](#72-the-budget)




## 9.1. Blocking Questions
From [`ARC_S9.1`](plan/ARC_architecture.md#91-open-questions-for-the-team). These gate the master
plan.

1. **Which scenario, and therefore which vocabulary?**
   The dataset, the demonstration, and the effectiveness score
2. **SgSL or ASL?**
   SgSL is the honest choice for a Singapore hackathon and the stronger differentiator; ASL has far
   more public data
3. **Who is the named person?**
   [`JCR_S4.4`](plan/JCR_judging_criteria.md#44-five-pressure-test-questions) question 1, which
   blocks the problem statement
4. **Where does the data come from?**
   Self-recorded, a public dataset, or both

---





# 10. GLOSSARY
## 10.1. Document Codes
1.  **`RIX`**
    `ref_index.md` — registry, addressing, formatting
2.  **`CLD`**
    `CLAUDE.md` — rules for AI agents
3.  **`RDM`**
    `README.md` — this file
4.  **`SCR`**
    `plan/scribbles.md` — raw ideation
5.  **`JCR`**
    `plan/JCR_judging_criteria.md`
6.  **`ARC`**
    `plan/ARC_architecture.md`
7.  **`RSK`**
    `plan/RSK_risk_register.md`
8.  **`TRN`**
    `doc/TRN_training_synthesis.md`
9.  **`APR` / `APS`**
    `ref_repo/apple/APR_apple_report.md` · `doc/APS_apple_synthesis.md`
10. **`MPR` / `MPS`**
    `ref_repo/google-mediapipe/MPR_mediapipe_report.md` · `doc/MPS_mediapipe_synthesis.md`
11. **`DHR` / `DHS`**
    `ref_repo/depthai-hand-tracker/DHR_depthai_report.md` · `doc/DHS_depthai_synthesis.md`
12. **`OPR` / `OPS`**
    `ref_repo/openpose/OPR_openpose_report.md` · `doc/OPS_openpose_synthesis.md`
13. **`RAP` `RMP` `RDH` `ROP`**
    The four clones themselves, git-ignored — [`RIX_S2.3`](ref_index.md#23-source-material)
14. **`D1`–`D6`**
    The six training PDFs in `doc/`
15. **`PLN` `TDO` `EVL` `DEC`**
    Reserved, not yet written — [`RIX_S2.2`](ref_index.md#22-planned-documents)

The repository-code pattern — tag + `R` for a report, tag + `S` for a synthesis — is in
[`RIX_S3.5`](ref_index.md#35-repository-document-codes). `APL`, `SYN` and `REF` were retired on
2026-08-30 — [`RIX_S2.4`](ref_index.md#24-retired-codes).




## 10.2. Domain Terms
1.  **SgSL**
    Singapore Sign Language. Its own language — a combination of Shanghainese Sign Language, ASL,
    Signing Exact English and locally developed signs
2.  **ASL**
    American Sign Language. Not SgSL, and not interchangeable with it
3.  **Gloss**
    A written label for a single sign. **Not** a word of the spoken language
4.  **Non-manual markers**
    Grammar carried by the face, head and torso — brow raise, headshake, mouthing. Syntax, not
    decoration
5.  **Coarticulation**
    Signs deforming under the influence of their neighbours. The reason continuous signing is far
    harder than isolated signs
6.  **Fingerspelling**
    Spelling a word letter by letter. Fast, heavily coarticulated, and used for exactly the content
    that matters most
7.  **Landmark**
    One tracked point on the body — MediaPipe emits 21 per hand, 33 for pose, 468 for face
8.  **Chirality / handedness**
    Which hand is which. Dominant and non-dominant hands carry different grammatical roles
9.  **Signing space**
    The volume in front of the signer where signs are made. Meaningful, and defined relative to the
    body
10. **Utterance**
    One unit of signing bounded by pauses. The unit of agent invocation

---





# 11. CREDITS AND SOURCES
- Training material © 2026 SimplifyNext — `doc/[D1]`–`doc/[D6]`.
- `ref_repo/apple/handpose/` is Apple Inc.'s *Detecting Hand Poses with Vision* sample (WWDC20
  session 10653), under Apple's sample-code licence. Ideas are ported; code is not —
  [`APR_S2.2`](ref_repo/apple/APR_apple_report.md#22-licence).
- `ref_repo/google-mediapipe/mediapipe/` is Google's MediaPipe, Apache 2.0 —
  [`MPR_S2.2`](ref_repo/google-mediapipe/MPR_mediapipe_report.md#22-licence).
- `ref_repo/depthai-hand-tracker/depthai_hand_tracker/` is `geaxgx/depthai_hand_tracker`, MIT —
  [`DHR_S2.2`](ref_repo/depthai-hand-tracker/DHR_depthai_report.md#22-licence).
- `ref_repo/openpose/openpose/` is CMU's OpenPose, **licensed for non-commercial academic research
  only**. Cited, never used — [`OPR_S2.2`](ref_repo/openpose/OPR_openpose_report.md#22-licence).
- Singapore Sign Language and interpreter figures: The Singapore Association for the Deaf,
  https://sadeaf.org.sg/.
- Hearing-loss figures: World Health Organization, *Deafness and hearing loss* fact sheet,
  https://www.who.int/news-room/fact-sheets/detail/deafness-and-hearing-loss.

Full source lists with reliability notes are in each document's `SOURCES` section.
