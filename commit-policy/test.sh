#!/usr/bin/env bash
#
# Tests check.sh against commits in a temporary repository. Usage: test.sh

set -uo pipefail

check="$(cd "$(dirname "$0")" && pwd)/check.sh"
repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
fails=0

g() {
	git -C "$repo" -c user.name=Committer -c user.email=committer@example.com \
		-c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# commit AUTHOR MESSAGE: adds an empty commit.
commit() {
	g commit -q --allow-empty --no-verify --author="$1" -m "$2"
}

# run RANGE: runs check.sh on RANGE, printing "pass" or "fail".
run() {
	if (cd "$repo" && env -u GITHUB_STEP_SUMMARY "$check" "$1" >/dev/null); then
		echo pass
	else
		echo fail
	fi
}

# expect STATUS AUTHOR MESSAGE: checks a single new commit.
expect() {
	local got
	commit "$2" "$3"
	got=$(run HEAD~1..HEAD)
	if [ "$got" != "$1" ]; then
		echo "FAIL: want $1, got $got: author $2: $3"
		fails=$((fails + 1))
	fi
}

human='Jesse Peterson <694298+jessepeterson@users.noreply.github.com>'
g init -q
commit "$human" 'chore: initial commit'
base=$(g rev-parse HEAD)

# Human co-authors and authors are fine.
expect pass "$human" 'feat: no trailers'
expect pass "$human" $'feat: human co-author\n\nCo-authored-by: Jesse Peterson <jesse@example.com>'
expect pass "$human" $'feat: names that are also tools\n\nCo-authored-by: Jules Verne <jules@example.com>\nCo-authored-by: Devin Smith <devin@example.com>'
expect pass "$human" $'feat: lookalike domain\n\nCo-authored-by: Max Power <max@max.ai.example.com>'
expect pass "$human" $'feat: assisted\n\nAssisted-by: Claude:claude-opus-5-5'
expect pass 'Cody Banks <cody@example.com>' 'feat: human author'

# AI agent co-author trailers, as written by the respective tools.
for trailer in \
	'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' \
	'Co-authored-by: Claude <noreply@anthropic.com>' \
	'co-authored-by: claude <noreply@example.com>' \
	'Co-authored-by: Copilot <175728472+Copilot@users.noreply.github.com>' \
	'Co-authored-by: Cursor Agent <cursoragent@cursor.com>' \
	'Co-authored-by: aider (gpt-4o) <noreply@aider.chat>' \
	'Co-authored-by: Codex <codex@openai.com>' \
	'Co-authored-by: ChatGPT <noreply@example.com>' \
	'Co-authored-by: GPT-5 <noreply@example.com>' \
	'Co-authored-by: Gemini <noreply@example.com>' \
	'Co-authored-by: google-labs-jules[bot] <161369871+google-labs-jules[bot]@users.noreply.github.com>' \
	'Co-authored-by: devin-ai-integration[bot] <158243242+devin-ai-integration[bot]@users.noreply.github.com>' \
	'Co-authored-by: Amp <amp@ampcode.com>' \
	'Co-authored-by: Grok <noreply@x.ai>'; do
	expect fail "$human" $'feat: ai co-author\n\n'"$trailer"
done

# Not a trailer by git's rules (no blank line before it) but still caught.
expect fail "$human" $'feat: inline\n\nSome body text.\nCo-authored-by: Claude <noreply@anthropic.com>'

# AI agent commit authors.
expect fail 'Copilot <198982749+Copilot@users.noreply.github.com>' 'feat: by copilot'
expect fail 'claude[bot] <209825114+claude[bot]@users.noreply.github.com>' 'feat: by claude'

# A range fails if any commit in it does; an empty range passes.
if [ "$(run "$base..HEAD")" != fail ]; then
	echo "FAIL: range containing violations passed"
	fails=$((fails + 1))
fi
if [ "$(run HEAD..HEAD)" != pass ]; then
	echo "FAIL: empty range failed"
	fails=$((fails + 1))
fi
if [ "$(run no-such-rev..HEAD 2>/dev/null)" != fail ]; then
	echo "FAIL: invalid range passed"
	fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
	echo "$fails test(s) failed"
	exit 1
fi
echo "all tests passed"
