"""Fail-closed GlossLattice policy and AgentGraph runtime composition."""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Mapping
from decimal import Decimal
from pathlib import Path
from time import perf_counter
from typing import cast

from pydantic import BaseModel, ConfigDict, Field, JsonValue, ValidationError

from simplynext.agent import (
    AgentGraph,
    AgentGraphNodes,
    AgentGraphState,
    AllowedToolExecutor,
    AssemblerDraft,
    BedrockCostGuard,
    BedrockLatticeAssemblerNode,
    BedrockLatticeCriticNode,
    BedrockPricing,
    CaptionTemplate,
    ConfidentResult,
    ConfirmedMemoryAdapter,
    CostGuardedConverseClient,
    CriticVerdict,
    DeterministicRepairNode,
    DraftEvidence,
    GapPart,
    GapReason,
    GraphOutcome,
    LatticeAssemblerConfig,
    LatticeCriticConfig,
    RepairPlan,
    RepairResult,
    SgslLexicon,
    Stage6ToolSet,
    SupportedTextPart,
    build_agent_graph,
    create_agent_state,
    create_anthropic_client,
    create_bedrock_client,
    create_bedrock_control_client,
    preflight_bedrock_access,
    preflight_bedrock_runtime_access,
    preflight_model_runtime_access,
    validate_draft_for_lattice,
)
from simplynext.agent.graph import AssemblerNode, CriticNode
from simplynext.config import Settings
from simplynext.contracts import (
    GlossLattice,
    GlossLatticeProducer,
    GlossProvenance,
    LatticeChoice,
    LatticeEvidenceTrace,
    LatticeRepairAction,
    LatticeRepairRequiredEvent,
    LatticeResultEvent,
    LatticeTerminalEvent,
    SignLanguage,
)
from simplynext.observability import MetricsRegistry

logger = logging.getLogger(__name__)


class _ConfidentPayload(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    caption: str = Field(min_length=1, max_length=500)
    tts_text: str | None = Field(default=None, min_length=1, max_length=500)
    confidence: float = Field(strict=True, ge=0.0, le=1.0, allow_inf_nan=False)
    agent_source: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
    agent_model_version: str | None = Field(
        default=None,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$",
    )


class _DeterministicLatticeAssembler:
    """Render only an exact configured template; represent every miss as gaps."""

    def __init__(self, templates: Mapping[tuple[str, ...], CaptionTemplate]) -> None:
        self._templates = dict(templates)

    def __call__(
        self,
        state: AgentGraphState,
        tools: AllowedToolExecutor,
    ) -> Mapping[str, JsonValue]:
        del tools
        lattice = state["lattice"]
        glosses = tuple(slot.resolved_gloss_id or "" for slot in lattice.slots)
        template = self._templates.get(glosses)
        if template is None:
            parts: tuple[SupportedTextPart | GapPart, ...] = tuple(
                GapPart(
                    kind="gap",
                    slot_id=slot.slot_id,
                    reason=GapReason.TRANSLATION_ABSTAINED,
                )
                for slot in lattice.slots
            )
            candidate_text = " ".join(f"[GAP:{slot.slot_id}]" for slot in lattice.slots)
        else:
            parts = (
                SupportedTextPart(
                    kind="supported_text",
                    text=template.caption,
                    evidence=tuple(
                        DraftEvidence(slot_id=slot.slot_id, gloss_id=gloss)
                        for slot, gloss in zip(lattice.slots, glosses, strict=True)
                    ),
                ),
            )
            candidate_text = template.caption
        draft = AssemblerDraft(
            schema_version="1.0",
            utterance_id=lattice.utterance_id,
            language=lattice.language,
            candidate_text=candidate_text,
            parts=parts,
        )
        validate_draft_for_lattice(draft, lattice)
        return cast(Mapping[str, JsonValue], draft.model_dump(mode="json"))


class _DeterministicLatticeCritic:
    """Approve only a fully grounded exact-template draft."""

    def __call__(
        self,
        state: AgentGraphState,
        tools: AllowedToolExecutor,
    ) -> CriticVerdict:
        del tools
        raw_draft = state.get("draft")
        if raw_draft is None:
            return CriticVerdict(supported=False, reason="critic_input_missing")
        try:
            draft = AssemblerDraft.model_validate_json(
                json.dumps(raw_draft, allow_nan=False, separators=(",", ":"))
            )
            validate_draft_for_lattice(draft, state["lattice"])
        except (TypeError, ValueError, ValidationError):
            return CriticVerdict(supported=False, reason="critic_input_invalid")
        if draft.has_gaps:
            return CriticVerdict(supported=False, reason="deterministic_template_missing")
        return CriticVerdict(supported=True, reason="exact_template_grounded")


class _ConfidentNode:
    def __init__(
        self,
        *,
        source: str,
        model_version: str | None,
        templates: Mapping[tuple[str, ...], CaptionTemplate] | None = None,
    ) -> None:
        self._source = source
        self._model_version = model_version
        self._templates = dict(templates or {})

    def __call__(
        self,
        state: AgentGraphState,
        tools: AllowedToolExecutor,
    ) -> ConfidentResult:
        del tools
        raw_draft = state.get("draft")
        if raw_draft is None:
            raise ValueError("confident result requires an assembler draft")
        draft = AssemblerDraft.model_validate_json(
            json.dumps(raw_draft, allow_nan=False, separators=(",", ":"))
        )
        validate_draft_for_lattice(draft, state["lattice"])
        if draft.has_gaps:
            raise ValueError("a draft containing gaps cannot become a confident result")
        glosses = tuple(slot.resolved_gloss_id or "" for slot in state["lattice"].slots)
        template = self._templates.get(glosses)
        payload = _ConfidentPayload(
            caption=draft.candidate_text,
            tts_text=(template.tts_text if template is not None else draft.candidate_text),
            confidence=_minimum_lattice_confidence(state["lattice"]),
            agent_source=self._source,
            agent_model_version=self._model_version,
        )
        return ConfidentResult(payload=cast(dict[str, JsonValue], payload.model_dump(mode="json")))


class LatticeTranslationEngine:
    """Apply deployment policy, invoke the bounded graph, and freeze its event result."""

    def __init__(
        self,
        *,
        agent_graph: AgentGraph,
        repair_node: DeterministicRepairNode,
        metrics: MetricsRegistry,
        approved_producer: GlossLatticeProducer,
        language: SignLanguage,
        min_confidence: float,
        min_margin: float,
        agent_source: str,
        agent_model_version: str | None,
        assembler_ready: bool,
        loop_cap: int,
    ) -> None:
        self.agent_graph = agent_graph
        self._repair_node = repair_node
        self.metrics = metrics
        self.approved_producer = approved_producer
        self.language = language
        self.min_confidence = min_confidence
        self.min_margin = min_margin
        self.agent_source = agent_source
        self.agent_model_version = agent_model_version
        self.assembler_ready = assembler_ready
        self.loop_cap = loop_cap

    @property
    def ready(self) -> bool:
        return self.assembler_ready

    async def process_lattice(
        self,
        lattice: GlossLattice,
        *,
        signer_id: str,
    ) -> LatticeTerminalEvent:
        """Return exactly one confident or fail-closed repair event."""

        started = perf_counter()
        try:
            policy_event = self._policy_event(lattice, signer_id=signer_id, started=started)
            if policy_event is not None:
                event: LatticeTerminalEvent = policy_event
            else:
                state = create_agent_state(
                    lattice,
                    signer_id=signer_id,
                    loop_cap=self.loop_cap,
                )
                agent_started = perf_counter()
                self.metrics.increment("lattice_agent_invocations")
                result_state = await self.agent_graph.ainvoke(
                    state,
                    thread_id=_thread_id(lattice, signer_id),
                )
                agent_ms = _elapsed_ms(agent_started)
                event = self._map_graph_result(
                    lattice,
                    result_state,
                    agent_ms=agent_ms,
                    total_ms=_elapsed_ms(started),
                )
        except Exception as exc:
            self.metrics.increment("lattice_agent_failures")
            logger.error(
                "lattice_agent_failed",
                extra={
                    "session_id": str(lattice.session_id),
                    "lattice_seq": lattice.lattice_seq,
                    "utterance_id": lattice.utterance_id,
                    "reason": type(exc).__name__,
                },
            )
            event = _repair_event(
                lattice,
                action=LatticeRepairAction.ESCALATE_HUMAN_INTERPRETER,
                reason_code="agent_execution_failed",
                message="The language service could not safely translate this utterance.",
                target_slot_ids=tuple(slot.slot_id for slot in lattice.slots),
                confidence=0.0,
                agent_source=self.agent_source,
                agent_model_version=self.agent_model_version,
                latency_ms={"total": _elapsed_ms(started)},
            )
        if isinstance(event, LatticeRepairRequiredEvent):
            self.metrics.increment("lattice_utterances_repair_required")
        self.metrics.observe_ms("lattice_utterance_total", event.latency_ms.get("total", 0))
        logger.info(
            "lattice_processed",
            extra={
                "session_id": str(lattice.session_id),
                "lattice_seq": lattice.lattice_seq,
                "utterance_id": lattice.utterance_id,
                "outcome": event.status,
                "agent_source": event.agent_source,
                "agent_model_version": event.agent_model_version,
                "latency_total_ms": event.latency_ms.get("total", 0),
            },
        )
        return event

    def _policy_event(
        self,
        lattice: GlossLattice,
        *,
        signer_id: str,
        started: float,
    ) -> LatticeRepairRequiredEvent | None:
        if lattice.language is not self.language:
            return self._policy_repair(
                lattice,
                reason_code="language_not_configured",
                target_slot_ids=tuple(slot.slot_id for slot in lattice.slots),
                started=started,
            )
        if lattice.producer != self.approved_producer:
            return self._policy_repair(
                lattice,
                reason_code="producer_profile_mismatch",
                target_slot_ids=tuple(slot.slot_id for slot in lattice.slots),
                started=started,
            )

        unresolved = tuple(
            slot for slot in lattice.slots if slot.provenance is GlossProvenance.UNRESOLVED
        )
        if unresolved:
            self.metrics.increment("lattice_unresolved_before_agent")
            base = create_agent_state(lattice, signer_id=signer_id, loop_cap=self.loop_cap)
            state = AgentGraphState(
                **base,
                draft=None,
                critique=CriticVerdict(supported=False, reason="unresolved_lattice_slot"),
                result=None,
                outcome=GraphOutcome.REPAIR_REQUIRED,
                node_path=(),
                run_record=None,
            )
            repair = self._repair_node(state, AllowedToolExecutor())
            return self._event_from_repair(
                lattice,
                repair,
                agent_ms=0,
                total_ms=_elapsed_ms(started),
                model_used=False,
            )

        for slot in lattice.slots:
            if slot.provenance is not GlossProvenance.CLASSIFIER_HIGH_CONFIDENCE:
                continue
            top = slot.candidates[0]
            if top.gloss_id.upper() in {"UNKNOWN", "OOV"}:
                return _repair_event(
                    lattice,
                    action=LatticeRepairAction.REQUEST_FINGERSPELLING,
                    reason_code="vocabulary_item_rejected",
                    message="Please fingerspell the intended word.",
                    target_slot_ids=(slot.slot_id,),
                    confidence=top.confidence,
                    agent_source="server_policy",
                    agent_model_version=None,
                    latency_ms={"policy": _elapsed_ms(started), "total": _elapsed_ms(started)},
                )
            second_confidence = slot.candidates[1].confidence if len(slot.candidates) > 1 else 0.0
            if top.confidence < self.min_confidence:
                return self._ambiguous_repair(
                    lattice,
                    slot_index=slot.slot_index,
                    reason_code="confidence_below_threshold",
                    started=started,
                )
            if top.confidence - second_confidence < self.min_margin:
                return self._ambiguous_repair(
                    lattice,
                    slot_index=slot.slot_index,
                    reason_code="confidence_margin_below_threshold",
                    started=started,
                )
        return None

    def _ambiguous_repair(
        self,
        lattice: GlossLattice,
        *,
        slot_index: int,
        reason_code: str,
        started: float,
    ) -> LatticeRepairRequiredEvent:
        slot = lattice.slots[slot_index]
        if len(slot.candidates) >= 2:
            action = LatticeRepairAction.OFFER_TOP_K
            choices = tuple(
                LatticeChoice(
                    slot_id=slot.slot_id,
                    rank=candidate.rank,
                    gloss_id=candidate.gloss_id,
                    confidence=candidate.confidence,
                )
                for candidate in slot.candidates
            )
            message = "Please choose the intended sign."
        else:
            action = LatticeRepairAction.ASK_REPEAT
            choices = ()
            message = "Please repeat the sign."
        elapsed = _elapsed_ms(started)
        return _repair_event(
            lattice,
            action=action,
            reason_code=reason_code,
            message=message,
            target_slot_ids=(slot.slot_id,),
            choices=choices,
            confidence=slot.candidates[0].confidence,
            agent_source="server_policy",
            agent_model_version=None,
            latency_ms={"policy": elapsed, "total": elapsed},
        )

    def _policy_repair(
        self,
        lattice: GlossLattice,
        *,
        reason_code: str,
        target_slot_ids: tuple[str, ...],
        started: float,
    ) -> LatticeRepairRequiredEvent:
        elapsed = _elapsed_ms(started)
        return _repair_event(
            lattice,
            action=LatticeRepairAction.ESCALATE_HUMAN_INTERPRETER,
            reason_code=reason_code,
            message="This lattice does not match the configured translation service.",
            target_slot_ids=target_slot_ids,
            confidence=0.0,
            agent_source="server_policy",
            agent_model_version=None,
            latency_ms={"policy": elapsed, "total": elapsed},
        )

    def _map_graph_result(
        self,
        lattice: GlossLattice,
        state: AgentGraphState,
        *,
        agent_ms: int,
        total_ms: int,
    ) -> LatticeTerminalEvent:
        result = state.get("result")
        if isinstance(result, ConfidentResult):
            payload = _ConfidentPayload.model_validate(result.payload)
            self.metrics.increment("lattice_utterances_confident")
            return LatticeResultEvent(
                session_id=lattice.session_id,
                lattice_seq=lattice.lattice_seq,
                utterance_id=lattice.utterance_id,
                evidence_trace=_evidence_trace(lattice),
                classifier_version=lattice.producer.classifier_version,
                agent_source=payload.agent_source,
                agent_model_version=payload.agent_model_version,
                latency_ms={"agent": agent_ms, "total": total_ms},
                caption=payload.caption,
                tts_text=payload.tts_text,
                confidence=payload.confidence,
                gloss_id_trace=tuple(
                    slot.resolved_gloss_id
                    for slot in lattice.slots
                    if slot.resolved_gloss_id is not None
                ),
            )
        if isinstance(result, RepairResult):
            return self._event_from_repair(
                lattice,
                result,
                agent_ms=agent_ms,
                total_ms=total_ms,
            )
        raise RuntimeError("AgentGraph returned no terminal result")

    def _event_from_repair(
        self,
        lattice: GlossLattice,
        result: RepairResult,
        *,
        agent_ms: int,
        total_ms: int,
        model_used: bool = True,
    ) -> LatticeRepairRequiredEvent:
        plan = RepairPlan.model_validate_json(
            json.dumps(result.details, allow_nan=False, separators=(",", ":"))
        )
        choices = tuple(
            LatticeChoice(
                slot_id=plan.unresolved_slot_ids[0],
                rank=option.rank,
                gloss_id=option.gloss_id,
                confidence=option.confidence,
            )
            for option in plan.options
        )
        return _repair_event(
            lattice,
            action=result.action,
            reason_code=_reason_code(plan.reason),
            message=plan.listener_notice,
            target_slot_ids=plan.unresolved_slot_ids,
            choices=choices,
            confidence=_repair_confidence(lattice, plan.unresolved_slot_ids),
            agent_source="deterministic_repair",
            agent_model_version=self.agent_model_version if model_used else None,
            latency_ms={"agent": agent_ms, "total": total_ms},
        )


def build_lattice_translation_engine(
    settings: Settings,
    metrics: MetricsRegistry,
) -> LatticeTranslationEngine:
    """Compose guarded model nodes or a deterministic, no-spend graph."""

    repair_node = DeterministicRepairNode(metrics=metrics)
    adapter = ConfirmedMemoryAdapter(metrics=metrics)
    tools = Stage6ToolSet(
        lexicon=SgslLexicon(
            lexicon_version=settings.lattice_vocabulary_version,
            entries=(),
        ),
        metrics=metrics,
    )
    templates = _load_caption_templates(settings.caption_templates_path)

    if settings.bedrock_enabled:
        preflight_bedrock_access(
            create_bedrock_control_client(region_name=settings.aws_region),
            region_name=settings.aws_region,
            model_id=settings.bedrock_model_id,
        )
        pricing = BedrockPricing(
            model_id=settings.bedrock_model_id,
            input_usd_per_million=settings.bedrock_input_usd_per_million_tokens,
            output_usd_per_million=settings.bedrock_output_usd_per_million_tokens,
            cache_write_usd_per_million=settings.bedrock_cache_write_usd_per_million_tokens,
            cache_read_usd_per_million=settings.bedrock_cache_read_usd_per_million_tokens,
        )
        guarded_client = CostGuardedConverseClient(
            client=create_bedrock_client(
                region_name=settings.aws_region,
                connect_timeout_seconds=settings.bedrock_connect_timeout_seconds,
                read_timeout_seconds=settings.bedrock_read_timeout_seconds,
                total_max_attempts=settings.bedrock_total_max_attempts,
            ),
            guard=BedrockCostGuard(
                pricing=pricing,
                spend_limit_usd=settings.bedrock_spend_limit_usd,
                known_spend_usd=settings.bedrock_known_spend_usd,
            ),
            metrics=metrics,
            prompt_cache_enabled=settings.bedrock_prompt_cache_enabled,
        )
        preflight_bedrock_runtime_access(
            guarded_client,
            region_name=settings.aws_region,
            model_id=settings.bedrock_model_id,
        )
        assembler: AssemblerNode = BedrockLatticeAssemblerNode(
            client=guarded_client,
            config=LatticeAssemblerConfig(model_id=settings.bedrock_model_id),
            metrics=metrics,
        )
        critic: CriticNode = BedrockLatticeCriticNode(
            client=guarded_client,
            config=LatticeCriticConfig(model_id=settings.bedrock_model_id),
            metrics=metrics,
        )
        confident = _ConfidentNode(
            source="bedrock_graph",
            model_version=settings.bedrock_model_id,
        )
        allowed_tools = tools.allowed_tools
        source = "bedrock_graph"
        model_version: str | None = settings.bedrock_model_id
        assembler_ready = True
    elif settings.anthropic_enabled:
        anthropic_rates = (
            settings.anthropic_input_usd_per_million_tokens,
            settings.anthropic_output_usd_per_million_tokens,
            settings.anthropic_cache_write_usd_per_million_tokens,
            settings.anthropic_cache_read_usd_per_million_tokens,
        )
        if any(rate is None for rate in anthropic_rates):
            raise ValueError("Anthropic pricing must be configured before startup")
        pricing = BedrockPricing(
            model_id=settings.anthropic_model_id,
            input_usd_per_million=cast(Decimal, settings.anthropic_input_usd_per_million_tokens),
            output_usd_per_million=cast(Decimal, settings.anthropic_output_usd_per_million_tokens),
            cache_write_usd_per_million=cast(
                Decimal, settings.anthropic_cache_write_usd_per_million_tokens
            ),
            cache_read_usd_per_million=cast(
                Decimal, settings.anthropic_cache_read_usd_per_million_tokens
            ),
        )
        guarded_client = CostGuardedConverseClient(
            client=create_anthropic_client(
                api_base_url=settings.anthropic_api_base_url,
                workspace_id=settings.anthropic_workspace_id,
                connect_timeout_seconds=settings.anthropic_connect_timeout_seconds,
                read_timeout_seconds=settings.anthropic_read_timeout_seconds,
                total_max_attempts=settings.anthropic_total_max_attempts,
            ),
            guard=BedrockCostGuard(
                pricing=pricing,
                spend_limit_usd=settings.anthropic_spend_limit_usd,
                known_spend_usd=settings.anthropic_known_spend_usd,
            ),
            metrics=metrics,
            prompt_cache_enabled=settings.anthropic_prompt_cache_enabled,
            provider="anthropic",
        )
        preflight_model_runtime_access(
            guarded_client,
            provider="anthropic",
            location=settings.anthropic_api_base_url,
            model_id=settings.anthropic_model_id,
        )
        assembler = BedrockLatticeAssemblerNode(
            client=guarded_client,
            config=LatticeAssemblerConfig(model_id=settings.anthropic_model_id),
            metrics=metrics,
        )
        critic = BedrockLatticeCriticNode(
            client=guarded_client,
            config=LatticeCriticConfig(model_id=settings.anthropic_model_id),
            metrics=metrics,
        )
        confident = _ConfidentNode(
            source="anthropic_graph",
            model_version=settings.anthropic_model_id,
        )
        allowed_tools = tools.allowed_tools
        source = "anthropic_graph"
        model_version = settings.anthropic_model_id
        assembler_ready = True
    else:
        assembler = _DeterministicLatticeAssembler(templates)
        critic = _DeterministicLatticeCritic()
        confident = _ConfidentNode(
            source="deterministic_template",
            model_version="deterministic_template_v1",
            templates=templates,
        )
        allowed_tools = ()
        source = "deterministic_template"
        model_version = "deterministic_template_v1"
        assembler_ready = bool(templates)

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=assembler,
            critic=critic,
            confident=confident,
            repair=repair_node,
            adapter=adapter,
        ),
        tool_registry=tools.registry,
        allowed_tools=allowed_tools,
    )
    return LatticeTranslationEngine(
        agent_graph=graph,
        repair_node=repair_node,
        metrics=metrics,
        approved_producer=settings.approved_lattice_producer,
        language=settings.recognition_language,
        min_confidence=settings.min_recognition_confidence,
        min_margin=settings.min_recognition_margin,
        agent_source=source,
        agent_model_version=model_version,
        assembler_ready=assembler_ready,
        loop_cap=settings.agent_max_revisions,
    )


def _load_caption_templates(path: Path | None) -> dict[tuple[str, ...], CaptionTemplate]:
    """Load exact no-spend caption templates; reject the complete file on drift."""

    if path is None:
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict) or payload.get("schema_version") != "1.0":
            raise ValueError("caption template schema_version must be '1.0'")
        raw_templates = payload.get("templates")
        if not isinstance(raw_templates, list):
            raise ValueError("caption templates must be an array")
        templates: dict[tuple[str, ...], CaptionTemplate] = {}
        for item in raw_templates:
            if not isinstance(item, dict) or set(item) - {"glosses", "caption", "tts_text"}:
                raise ValueError("caption template has an invalid shape")
            glosses = item.get("glosses")
            caption = item.get("caption")
            tts_text = item.get("tts_text")
            if not isinstance(glosses, list) or not glosses or not all(
                isinstance(value, str) and value for value in glosses
            ):
                raise ValueError("caption template glosses must be non-empty strings")
            if not isinstance(caption, str) or (
                tts_text is not None and not isinstance(tts_text, str)
            ):
                raise ValueError("caption template text is invalid")
            key = tuple(glosses)
            if key in templates:
                raise ValueError("duplicate caption template")
            templates[key] = CaptionTemplate(caption=caption, tts_text=tts_text)
        return templates
    except (OSError, ValueError, TypeError) as exc:
        logger.error("caption_templates_rejected", extra={"reason": type(exc).__name__})
        return {}


def _repair_event(
    lattice: GlossLattice,
    *,
    action: LatticeRepairAction,
    reason_code: str,
    message: str,
    target_slot_ids: tuple[str, ...],
    confidence: float,
    agent_source: str | None,
    agent_model_version: str | None,
    latency_ms: dict[str, int],
    choices: tuple[LatticeChoice, ...] = (),
) -> LatticeRepairRequiredEvent:
    return LatticeRepairRequiredEvent(
        session_id=lattice.session_id,
        lattice_seq=lattice.lattice_seq,
        utterance_id=lattice.utterance_id,
        evidence_trace=_evidence_trace(lattice),
        classifier_version=lattice.producer.classifier_version,
        agent_source=agent_source,
        agent_model_version=agent_model_version,
        latency_ms=latency_ms,
        repair_id=f"repair:{lattice.lattice_seq}",
        action=action,
        message=message,
        confidence=max(0.0, min(1.0, confidence)),
        target_slot_ids=target_slot_ids,
        choices=choices,
        reason_codes=(_reason_code(reason_code),),
    )


def _evidence_trace(lattice: GlossLattice) -> tuple[LatticeEvidenceTrace, ...]:
    evidence: list[LatticeEvidenceTrace] = []
    for slot in lattice.slots:
        selected = next(
            (
                candidate
                for candidate in slot.candidates
                if candidate.gloss_id == slot.resolved_gloss_id
            ),
            None,
        )
        evidence.append(
            LatticeEvidenceTrace(
                slot_index=slot.slot_index,
                slot_id=slot.slot_id,
                start_ms=slot.start_ms,
                end_ms=slot.end_ms,
                resolved_gloss_id=slot.resolved_gloss_id,
                confidence=None if selected is None else selected.confidence,
                provenance=slot.provenance,
                candidates=slot.candidates,
            )
        )
    return tuple(evidence)


def _minimum_lattice_confidence(lattice: GlossLattice) -> float:
    confidences = [
        candidate.confidence
        for slot in lattice.slots
        for candidate in slot.candidates
        if candidate.gloss_id == slot.resolved_gloss_id
    ]
    return min(confidences, default=1.0)


def _repair_confidence(lattice: GlossLattice, target_slot_ids: tuple[str, ...]) -> float:
    if not target_slot_ids:
        return _minimum_lattice_confidence(lattice)
    targets = set(target_slot_ids)
    confidences = [
        slot.candidates[0].confidence if slot.candidates else 0.0
        for slot in lattice.slots
        if slot.slot_id in targets
    ]
    return min(confidences, default=0.0)


def _thread_id(lattice: GlossLattice, signer_id: str) -> str:
    return f"lattice:{lattice.session_id}:{signer_id}"


def _reason_code(reason: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9_.:-]+", "_", reason.strip())[:128]
    if not normalized or not normalized[0].isalnum():
        return "repair_required"
    return normalized


def _elapsed_ms(started: float) -> int:
    return max(0, round((perf_counter() - started) * 1000))


__all__ = ["LatticeTranslationEngine", "build_lattice_translation_engine"]
