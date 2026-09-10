#!/bin/sh
# Minimal stand-in for the `claude` CLI used by the C9 harness tests.
#
# Recognises the same call shapes as the real CLI:
#   claude --version        -> prints a version banner
#   claude -p "<prompt>" ... -> emits a single trailing JSON result event
#                               ({type:"result"}) exactly like
#                               `claude -p --output-format json`
#
# The prompt text selects the simulated behaviour (tests rely on this):
#   - prompts starting with "crash"  exit 3 after printing "boom"
#   - prompts starting with "raw"    print plain text (no result event)
#   - prompts starting with "error"  emit an error result event
#   - prompts starting with "slow"   sleep 5s before emitting a result event
#   - anything else                  emit a successful result event with usage

version="9.9.9 (fake claude)"

if [ "$1" = "--version" ]; then
	echo "$version"
	exit 0
fi

prompt="$2"

case "$prompt" in
error*)
	printf '%s\n' '{"type":"result","subtype":"error_during_execution","result":"agent failed","is_error":true}'
	exit 0
	;;
crash*)
	echo "boom"
	exit 3
	;;
raw*)
	printf '%s\n' "plain text output"
	exit 0
	;;
slow*)
	sleep 5
	printf '%s\n' '{"type":"result","subtype":"success","result":"late","is_error":false}'
	exit 0
	;;
esac

printf '%s\n' '{"type":"result","subtype":"success","result":"PONG","session_id":"fake-session-123","total_cost_usd":0.012345,"usage":{"input_tokens":42,"output_tokens":7},"duration_ms":321,"is_error":false}'
exit 0
