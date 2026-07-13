#!/usr/bin/env bash
# Simulates an auth/rate-limit failure: message on stderr, non-zero exit.
echo "simulated rate-limit lockout (429)" >&2
exit 1
