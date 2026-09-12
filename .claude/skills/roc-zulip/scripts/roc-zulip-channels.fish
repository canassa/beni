#!/usr/bin/env fish
# List Roc Zulip channels, ranked by recent activity.
#
# /json/streams requires authentication, so anonymously we discover channels by
# sampling recent web-public messages and aggregating their display_recipient.
# Quiet channels may therefore be missing — raise --sample to see more.
#
# Usage: roc-zulip-channels.fish [--sample N] [--json]

source (status dirname)/_common.fish

argparse 's/sample=' 'j/json' 'h/help' -- $argv
or exit 1

if set -q _flag_help
    echo "usage: roc-zulip-channels.fish [--sample N] [--json]"
    echo "  --sample N   messages to sample (default 1000, max 1000 per request)"
    exit 0
end

set -l sample 1000
set -q _flag_sample; and set sample $_flag_sample
test $sample -gt 1000; and set sample 1000

if _rz_authed
    # With credentials the real endpoint is available and authoritative.
    set -l json (_rz_get streams include_public=true include_web_public=true | string collect)
    or exit 1
    if set -q _flag_json
        printf '%s\n' $json
        exit 0
    end
    printf '%s' $json | jq -r '.streams[] | "\(.stream_id)\t\(.name)\t\(.description // "")"' | sort -n
    exit 0
end

set -l json (_rz_get messages \
    anchor=newest num_before=$sample num_after=0 apply_markdown=false \
    "narrow="(_rz_narrow) | string collect)
or exit 1

if set -q _flag_json
    printf '%s\n' $json
    exit 0
end

set -l n (printf '%s' $json | jq '.messages | length')
echo "# channels seen in the last $n web-public messages (most active first)"
echo "# msgs  id       channel"
printf '%s' $json \
    | jq -r '.messages[] | "\(.stream_id)\t\(.display_recipient)"' \
    | sort | uniq -c | sort -rn \
    | awk '{ id=$2; $1=$1; count=$1; name=""; for (i=3;i<=NF;i++) name = name (i>3 ? " " : "") $i; printf "%6d  %-8s %s\n", count, id, name }'
