#!/usr/bin/env python3
"""
Run the OpenCode Zen gate probe with `requests` instead of `urllib`.

The reference probe (zen_fingerprint.py) uses urllib.request, whose default SSL
context on this Mac cannot reach opencode.ai (CERTIFICATE_VERIFY_FAILED).
`requests` uses its own context that does. This wrapper swaps the transport so
the same shipping logic is exercised against the live endpoint.
"""
from __future__ import annotations

import sys

import requests

import zen_fingerprint


def requests_post(headers: dict, body: dict, endpoint: str = zen_fingerprint.ENDPOINT, timeout: int = 90):
    resp = requests.post(endpoint, headers=headers, json=body, timeout=timeout)
    return resp.status_code, resp.text


zen_fingerprint.post = requests_post

if __name__ == "__main__":
    sys.exit(zen_fingerprint.main())