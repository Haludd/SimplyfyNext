"""Authentication helpers for operator-only diagnostics."""

from __future__ import annotations

import hmac

from fastapi import HTTPException, status
from pydantic import SecretStr


def require_operator_token(
    token: SecretStr | None,
    authorization: str | None,
    *,
    allow_unconfigured: bool,
) -> None:
    """Require a dedicated bearer token without ever accepting a client stream token."""

    if token is None:
        if allow_unconfigured:
            return
        # Hide an unprotected production diagnostic endpoint rather than advertising it.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")
    if authorization is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Operator bearer token required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    scheme, separator, presented = authorization.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not presented.strip():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid operator authorization",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if not hmac.compare_digest(presented.strip(), token.get_secret_value()):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid operator authorization",
            headers={"WWW-Authenticate": "Bearer"},
        )

