#!/usr/bin/env python3
"""Render Hermes ``chat --format stream-json`` events as compact log lines."""

from __future__ import annotations

import json
import sys
from typing import Any


def text(value: Any) -> str:
    if isinstance(value, str):
        return " ".join(value.split())
    if isinstance(value, list):
        return " ".join(part for item in value if (part := text(item)))
    if isinstance(value, dict):
        for key in ("text", "content", "message", "output", "result"):
            if key in value:
                rendered = text(value[key])
                if rendered:
                    return rendered
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return ""


def compact(value: Any, limit: int = 500) -> str:
    rendered = text(value)
    return rendered if len(rendered) <= limit else f"{rendered[:limit - 1]}…"


def render(event: dict[str, Any]) -> list[str]:
    event_type = str(event.get("type", "event")).replace("_", ".")
    if event_type in {"error", "turn.failed", "run.failed"}:
        return [f"[hermes:error] {compact(event.get('error') or event.get('message') or event)}"]
    if event_type in {"turn.completed", "run.completed", "complete", "done"}:
        return ["[hermes] turn completed"]

    payload = event.get("item") or event.get("data") or event
    if "tool" in event_type or "command" in event_type:
        return [f"[hermes:tool] {compact(payload)}"]
    if "thinking" in event_type or "reasoning" in event_type:
        return [f"[hermes:thinking] {compact(payload)}"]
    message = compact(payload)
    return [f"[hermes:{event_type}] {message}".rstrip()] if message else []


def main() -> None:
    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            print(line, flush=True)
            continue
        if not isinstance(event, dict):
            print(line, flush=True)
            continue
        for output in render(event):
            print(output, flush=True)


if __name__ == "__main__":
    main()
