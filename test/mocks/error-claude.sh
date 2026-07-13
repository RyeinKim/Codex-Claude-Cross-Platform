#!/usr/bin/env bash
# Simulates claude -p returning an error ENVELOPE (is_error:true) with exit 0.
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"RATE LIMIT: retry after 3600s"}\n'
