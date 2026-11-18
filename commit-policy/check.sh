#!/usr/bin/env bash
#
# Checks commits against the commit message rules in the MicroMDM
# contributing guide:
# https://github.com/micromdm/.github/blob/main/CONTRIBUTING.md
#
# Usage: check.sh [REVISION_RANGE]
#
# With a revision range (e.g. "upstream/main..HEAD"), checks those commits in
# the current repository. Use this to check your branch before pushing.
#
# With no argument (as the GitHub action runs it), fetches the commits of the
# pull request being built into a temporary repository and checks those. This
# uses environment variables set by action.yml: EVENT_NAME, SERVER_URL, REPO,
# BASE_SHA, HEAD_SHA, and optionally TOKEN.

set -euo pipefail

guide='https://github.com/micromdm/.github/blob/main/CONTRIBUTING.md#llms--ai'

# Case-insensitive extended regular expressions matched against "Name <email>"
# identities to recognize AI agents.
ai_patterns=(
	'anthropic\.com' '\bclaude\b'
	'openai\.com' '\bchatgpt\b' '\bcodex\b' '\bgpt-?[0-9]'
	'copilot'
	'cursor\.com' '\bcursor ?agent\b' '\bcursor\[bot\]'
	'\bgemini\b' 'google-labs-jules'
	'aider\.chat'
	'devin-ai-integration' '\bdevin\.ai\b' 'cognition\.ai'
	'ampcode\.com'
	'codeium' 'windsurf'
	'opencode'
	'\bgrok\b' '[@.]x\.ai\b'
	'deepseek' '\bqwen\b' 'mistral\.ai'
	'\bkiro\b' '\bjunie\b'
	'\bllm\b'
)
ai_pattern=$(
	IFS='|'
	echo "${ai_patterns[*]}"
)

is_ai() {
	grep -Eiq -- "$ai_pattern" <<<"$1"
}

# Escapes data for a workflow command message.
escape() {
	local s=${1//'%'/%25}
	s=${s//$'\r'/%0D}
	printf '%s' "${s//$'\n'/%0A}"
}

# Fetches the pull request's base and head commits into a new repository at
# $1. Only commit objects are fetched (no trees or file contents): the checks
# need nothing more.
fetch_pr() {
	local dir=$1 header='' attempt
	git init -q "$dir"
	git -C "$dir" remote add origin "$SERVER_URL/$REPO.git"
	if [ -n "${TOKEN:-}" ]; then
		header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
	fi
	for attempt in 1 2 3; do
		# The token is passed in the environment, keeping it out of the
		# process list and off disk.
		if GIT_TERMINAL_PROMPT=0 \
			GIT_CONFIG_COUNT=1 \
			GIT_CONFIG_KEY_0="http.$SERVER_URL/.extraheader" \
			GIT_CONFIG_VALUE_0="$header" \
			git -C "$dir" fetch -q --no-tags --filter=tree:0 origin "$BASE_SHA" "$HEAD_SHA"; then
			return 0
		fi
		[ "$attempt" -lt 3 ] && sleep $((attempt * 5))
	done
	echo "::error title=Commit policy::Failed to fetch pull request commits."
	return 1
}

if [ $# -gt 0 ]; then
	range=$1
else
	case "${EVENT_NAME:-}" in
	pull_request | pull_request_target) ;;
	*)
		echo "::notice title=Commit policy::Skipped: only pull request events are checked (got '${EVENT_NAME:-}')."
		exit 0
		;;
	esac
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	fetch_pr "$work"
	cd "$work"
	range="$BASE_SHA..$HEAD_SHA"
fi

shas=$(git rev-list --reverse "$range" --)

violations=()
violation() {
	echo "::error title=AI Co-authored-by::$(escape "$1")"
	violations+=("$1")
}

for sha in $shas; do
	short=${sha:0:12}

	author=$(git log -1 --format='%an <%ae>' "$sha")
	if is_ai "$author"; then
		violation "Commit $short is authored by an AI agent: $author"
	fi

	# Any Co-authored-by line counts, not just those git parses as trailers,
	# so placement (e.g. no blank line before it) can't slip one through.
	while IFS= read -r line; do
		if is_ai "$line"; then
			violation "Commit $short has a Co-authored-by trailer naming an AI agent: $line"
		fi
	done < <(git log -1 --format=%B "$sha" | grep -Ei '^[[:space:]]*co-authored-by[[:space:]]*:' || true)
done

if [ ${#violations[@]} -eq 0 ]; then
	echo "No commits name an AI agent as co-author."
	exit 0
fi

help="Per the contributing guide ($guide), commits must not include a \
Co-authored-by trailer that names an AI agent, and must be authored by a \
human. Credit AI assistance with an Assisted-by trailer instead, e.g. \
'Assisted-by: Claude Code:claude-opus-5-0'. Reword the affected commits \
(e.g. with 'git rebase -i') and force push (with lease) your branch."
echo "$help"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### Commit policy: AI Co-authored-by"
		echo
		printf -- '- %s\n' "${violations[@]}"
		echo
		echo "$help"
	} >>"$GITHUB_STEP_SUMMARY"
fi

exit 1
