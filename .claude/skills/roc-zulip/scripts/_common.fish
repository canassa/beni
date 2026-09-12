# Shared helpers for the roc-zulip scripts. Sourced, not executed.
#
# Anonymous access rule (verified 2026-09-12):
#   * base path must be /json/... — /api/v1/... always returns 401 without credentials
#   * the narrow must include {"operator":"channels","operand":"web-public"}
#   * no cookie, no CSRF header, no API key required for GET
# Setting ZULIP_EMAIL + ZULIP_API_KEY switches to /api/v1 with basic auth and
# drops the web-public term, which also reaches private channels.

function _rz_site
    if set -q ROC_ZULIP_SITE; and test -n "$ROC_ZULIP_SITE"
        echo $ROC_ZULIP_SITE
    else
        echo https://roc.zulipchat.com
    end
end

# Succeeds when credentials are available.
function _rz_authed
    set -q ZULIP_EMAIL; and set -q ZULIP_API_KEY
    and test -n "$ZULIP_EMAIL"; and test -n "$ZULIP_API_KEY"
end

function _rz_base
    if _rz_authed
        echo (_rz_site)"/api/v1"
    else
        echo (_rz_site)"/json"
    end
end

# JSON-quote an arbitrary string safely.
function _rz_str
    printf '%s' "$argv[1]" | jq -R .
end

function _rz_term_channel
    printf '{"operator":"channel","operand":%s}' (_rz_str "$argv[1]")
end

function _rz_term_topic
    printf '{"operator":"topic","operand":%s}' (_rz_str "$argv[1]")
end

function _rz_term_sender
    printf '{"operator":"sender","operand":%s}' (_rz_str "$argv[1]")
end

function _rz_term_search
    printf '{"operator":"search","operand":%s}' (_rz_str "$argv[1]")
end

function _rz_term_id
    printf '{"operator":"id","operand":%s}' (_rz_str "$argv[1]")
end

# Build the narrow array, prepending the web-public term when anonymous.
function _rz_narrow
    set -l terms
    if not _rz_authed
        set terms '{"operator":"channels","operand":"web-public"}'
    end
    for t in $argv
        test -n "$t"; and set terms $terms $t
    end
    echo "["(string join ',' $terms)"]"
end

# _rz_get <path> [key=value ...] -> raw JSON on stdout, non-zero on API error.
function _rz_get
    set -l path $argv[1]
    set -l args
    for kv in $argv[2..-1]
        set args $args --data-urlencode "$kv"
    end
    if _rz_authed
        set args $args -u "$ZULIP_EMAIL:$ZULIP_API_KEY"
    end

    set -l resp (curl -sS -G (_rz_base)"/$path" $args | string collect)
    if test $status -ne 0
        echo "roc-zulip: request failed (network or curl error)" >&2
        return 1
    end

    set -l result (printf '%s' $resp | jq -r '.result // "error"')
    if test "$result" != success
        set -l msg (printf '%s' $resp | jq -r '.msg // "unknown error"')
        echo "roc-zulip: $msg" >&2
        if not _rz_authed
            echo "roc-zulip: note - anonymous access only covers web-public channels." >&2
            echo "roc-zulip: set ZULIP_EMAIL and ZULIP_API_KEY to reach private ones." >&2
        end
        return 1
    end

    printf '%s\n' $resp
end

# Human-readable message rendering. Timestamps are UTC.
set -g RZ_JQ_MSG '.messages[] | "── #\(.display_recipient) › \(.subject)\n   \(.sender_full_name) · \((.timestamp|gmtime|strftime("%Y-%m-%d %H:%M")))Z · id \(.id)\n\(.content)\n"'

# Compact one-line-per-hit rendering, used by search.
set -g RZ_JQ_HIT '.messages[] | "\((.timestamp|gmtime|strftime("%Y-%m-%d"))) #\(.display_recipient) › \(.subject) · \(.sender_full_name) · id \(.id)\n    \((.content|gsub("\\s+";" ")|.[0:220]))"' # NOTE: \\\\s below survives fish quoting as \\s for jq
set -g RZ_JQ_HIT '.messages[] | "\((.timestamp|gmtime|strftime("%Y-%m-%d"))) #\(.display_recipient) › \(.subject) · \(.sender_full_name) · id \(.id)\n    \((.content|gsub("\\\\s+";" ")|.[0:220]))"'

# Permalink for a message. Topic encoding is Zulip's percent-encoding with "."
# in place of "%" — best effort, resolves for ordinary topic names.
function _rz_link
    set -l stream_id $argv[1]
    set -l channel $argv[2]
    set -l topic $argv[3]
    set -l msg_id $argv[4]
    set -l cslug (printf '%s' "$channel" | string replace -ra '[^a-zA-Z0-9]+' '-')
    set -l tslug (printf '%s' "$topic" | jq -rR '@uri' | string replace -a '%' '.')
    set -l url (_rz_site)"/#narrow/channel/$stream_id-$cslug/topic/$tslug"
    if test -n "$msg_id"
        set url "$url/near/$msg_id"
    end
    echo $url
end

# Resolve a channel name to its numeric id by asking for one message from it.
function _rz_channel_id
    set -l name $argv[1]
    if string match -qr '^[0-9]+$' -- $name
        echo $name
        return 0
    end
    set -l json (_rz_get messages \
        anchor=newest num_before=1 num_after=0 \
        "narrow="(_rz_narrow (_rz_term_channel $name)) | string collect)
    or return 1
    set -l id (printf '%s' $json | jq -r '.messages[0].stream_id // empty')
    if test -z "$id"
        echo "roc-zulip: no messages visible in channel '$name' - check the name with roc-zulip-channels.fish" >&2
        return 1
    end
    echo $id
end
