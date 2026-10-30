#!/bin/sh
# A single JSON-RPC response on stdio: never echo a parent-supplied expected value.
printf '{"jsonrpc":"2.0","id":1,"result":{"marker":"%s"}}\n' "${AGENCIL_CHAIN_MARKER:-missing}"
