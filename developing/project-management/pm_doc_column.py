"""Resolve the PM document column from a current table schema on stdin."""

import json
import sys


def resolve(schema):
    columns = [column for column in schema["columns"]
               if column.get("type") == "blob" and column.get("options", {}).get("kind") == "text"]
    named = [column for column in columns if column.get("name") == "Doc"]
    candidates = named or columns
    if len(candidates) != 1:
        raise ValueError("PM requires a Doc text blob column, or exactly one text blob column")
    return candidates[0]["column_id"]


if __name__ == "__main__":
    try:
        print(resolve(json.load(sys.stdin)))
    except (KeyError, TypeError, ValueError) as error:
        sys.exit(f"pm: {error}")
