"""Safe deterministic prompts; neither provider text nor drafts reach a repair."""

from simplynext.contracts.room_events import Reason, RepairAction, RepairOutcome


def repair(reason: Reason, indices: tuple[int, ...] = ()) -> RepairOutcome:
    action: RepairAction
    if reason == "unsupported_vocabulary":
        action, prompt = (
            "request_fingerspelling",
            "Please fingerspell the word or type your message.",
        )
    elif reason in {"low_score", "ambiguous_words", "unresolved_content"}:
        action, prompt = "ask_repeat", "Please sign the message again, or type it."
    else:
        action, prompt = "ask_type", "Please type your message to continue."
    return RepairOutcome(action=action, prompt=prompt, reason_code=reason, target_indices=indices)
