"""Ephemeral spend scopes propagated to provider threads, never to provider payloads."""

from contextvars import ContextVar
from dataclasses import dataclass, field
from decimal import Decimal
from threading import RLock
from uuid import uuid4

# The same short lock protects reservation, settlement and deletion across threads.
# It is never held over network I/O.
SPEND_LOCK = RLock()


@dataclass
class SpendAccount:
    spent: Decimal = Decimal(0)
    reserved: Decimal = Decimal(0)
    closed: bool = False

    def erase(self) -> None:
        with SPEND_LOCK:
            self.closed = True
            self.spent = self.reserved = Decimal(0)


@dataclass
class SpendScope:
    room: SpendAccount
    request: SpendAccount = field(default_factory=SpendAccount)
    # Server-generated correlation, independent of client-selected message IDs.
    correlation_id: str = field(default_factory=lambda: uuid4().hex)


current_spend_scope: ContextVar[SpendScope | None] = ContextVar("spend_scope", default=None)
