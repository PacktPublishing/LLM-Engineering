import argparse
import hashlib
import json
import os
import sys
import tempfile
import traceback
from contextlib import closing
from datetime import datetime, timezone
from http.client import HTTPConnection, HTTPException
from pathlib import Path
from typing import Optional

WEBSERVER_HOST = "localhost"
WEBSERVER_ENDPOINT = "/api/provenance/call"
PORT_FILE_SUFFIX = "-provenance-port.txt"


class ProvenanceHookError(RuntimeError):
    pass


def http_request(
    method,
    host,
    port,
    location,
    *,
    body: Optional[bytes] = None,
    headers: Optional[dict] = None,
    timeout=None,
    wait_for_response=False,
) -> bytes:
    with closing(HTTPConnection(host, port, timeout=timeout)) as connection:
        connection.request(method, location, body=body, headers=headers or {})
        if wait_for_response:
            response = connection.getresponse()

            return response.read()

    return b""


def get_server_port():
    claude_root = os.getenv("CLAUDE_PROJECT_DIR")
    path_hash = hashlib.md5(claude_root.encode("utf-8")).hexdigest()
    port_file = Path(tempfile.gettempdir()) / (path_hash + PORT_FILE_SUFFIX)

    return int(port_file.read_text("utf-8").strip())


def send_diff_to_webserver(file_path, timestamp_ms, wait_for_response):
    try:
        port = get_server_port()
    except FileNotFoundError as e:
        raise ProvenanceHookError(f"Could not determine API port: {e.filename} does not exist") from e
    except Exception as e:
        raise ProvenanceHookError("Could not determine API port") from e

    url = f"http://{WEBSERVER_HOST}:{port}{WEBSERVER_ENDPOINT}"

    try:
        payload = {"file_path": file_path, "timestamp": timestamp_ms}
        return http_request(
            "POST",
            WEBSERVER_HOST,
            port=port,
            location=WEBSERVER_ENDPOINT,
            body=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            timeout=0.5,
            wait_for_response=wait_for_response,
        )

    except (HTTPException, OSError, ConnectionError) as e:
        raise ProvenanceHookError(f"Network error while sending diff to {url}") from e
    except Exception as e:
        raise ProvenanceHookError(f"Unknown error while sending diff to {url}") from e


def extract_file_path(tool_name, tool_input):
    if tool_name in ["Write", "Edit", "MultiEdit"]:
        return tool_input.get("file_path", "unknown")
    if tool_name == "NotebookEdit":
        return tool_input.get("notebook_path", "unknown")
    return "unknown"


def excepthook(type, value, traceback_):
    traceback.print_exception(type, value, traceback_, file=sys.stderr)
    sys.exit(1)


def main():
    data = json.load(sys.stdin)
    tool_name = data.get("tool_name", "unknown")

    p = argparse.ArgumentParser()
    p.add_argument("--wait_for_response", default=False)
    args = p.parse_args()

    modification_tools = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    if tool_name in modification_tools:
        tool_input = data.get("tool_input", {})
        file_path = extract_file_path(tool_name, tool_input)
        if file_path:
            timestamp_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
            send_diff_to_webserver(file_path, timestamp_ms, args.wait_for_response)


if __name__ == "__main__":
    sys.excepthook = excepthook
    sys.exit(main())
