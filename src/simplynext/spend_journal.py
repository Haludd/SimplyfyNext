"""Atomic, content-free deployment accounting for a single process and volume."""

import json
import os
from decimal import Decimal
from pathlib import Path
from tempfile import NamedTemporaryFile


class SpendJournal:
    def __init__(self, path: Path) -> None:
        import fcntl

        self.path = path
        if not path.is_absolute() or not path.parent.is_dir():
            raise ValueError("spend journal requires an absolute path on an existing volume")
        self._writer_lock = os.fdopen(
            os.open(
                path.with_suffix(".lock"),
                os.O_CREAT | os.O_RDWR,
                0o600,
            ),
            "w",
        )
        try:
            fcntl.flock(self._writer_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self._writer_lock.close()
            raise ValueError("deployment spend journal already has an active writer") from None

    def close(self) -> None:
        self._writer_lock.close()

    def read(self) -> tuple[Decimal, dict[int, Decimal]]:
        if not self.path.exists():
            return Decimal(0), {}
        try:
            if self.path.stat().st_size > 16384:
                raise ValueError("oversized journal")
            raw = json.loads(self.path.read_bytes())
            if set(raw) != {"version", "charged_usd", "hourly"} or raw["version"] != 1:
                raise ValueError("invalid journal")
            spent = money(raw["charged_usd"])
            buckets = {int(k): money(v) for k, v in raw["hourly"].items()}
            if len(buckets) > 62 or sum(buckets.values(), Decimal(0)) > spent:
                raise ValueError("invalid buckets")
            return spent, buckets
        except (ValueError, TypeError, KeyError, AttributeError, ArithmeticError) as exc:
            raise ValueError(
                "deployment spend journal is invalid; reconcile before restart"
            ) from exc

    def write(self, spent: Decimal, buckets: dict[int, Decimal]) -> None:
        # Reserve-to-disk BEFORE dispatch. An interrupted/unknown call remains
        # fully charged after restart. No room or provider payload is serialized.
        data = json.dumps(
            {
                "version": 1,
                "charged_usd": str(spent),
                "hourly": {str(k): str(v) for k, v in buckets.items()},
            }
        ).encode()
        temporary: Path | None = None
        try:
            with NamedTemporaryFile(dir=self.path.parent, prefix=".spend-", delete=False) as file:
                temporary = Path(file.name)
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def money(value: object) -> Decimal:
    if not isinstance(value, str):
        raise ValueError("invalid money")
    result = Decimal(value)
    if not result.is_finite() or result < 0:
        raise ValueError("invalid money")
    return result


def init_spend_journal(path: Path, *, charged_usd: Decimal = Decimal(0)) -> None:
    """Safely provision a fresh usage.json journal using exclusive creation (never overwrite)."""
    if not path.is_absolute() or not path.parent.is_dir():
        raise ValueError("spend journal requires an absolute path on an existing volume")
    data = json.dumps(
        {
            "version": 1,
            "charged_usd": str(charged_usd),
            "hourly": {},
        }
    ).encode()
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python -m simplynext.spend_journal <usage.json> [initial_usd]")
        sys.exit(1)
    target = Path(sys.argv[1]).resolve()
    initial_charge = Decimal(sys.argv[2]) if len(sys.argv) > 2 else Decimal(0)
    init_spend_journal(target, charged_usd=initial_charge)
    print(f"Provisioned spend journal at {target}")
