# Shared helpers for the hackernews scripts. Sourced, not executed.
#
# Everything goes through Algolia's public HN index (hn.algolia.com/api/v1).
# No key, no login, no headers. Verified 2026-09-20.
#
# Environment overrides:
#   HN_API_BASE   default https://hn.algolia.com/api/v1
#   HN_TIMEOUT    per-request seconds, default 30

function _hn_base
    if set -q HN_API_BASE; and test -n "$HN_API_BASE"
        echo $HN_API_BASE
    else
        echo https://hn.algolia.com/api/v1
    end
end

function _hn_timeout
    if set -q HN_TIMEOUT; and test -n "$HN_TIMEOUT"
        echo $HN_TIMEOUT
    else
        echo 30
    end
end

function _hn_die
    echo "hn: $argv[1]" >&2
    return 1
end

# _hn_get <path> [key=value ...] -> raw JSON on stdout, non-zero on failure.
# Retries once on 429 and 5xx; everything else fails fast with the API's message.
function _hn_get
    set -l path $argv[1]
    set -l args
    for kv in $argv[2..-1]
        test -n "$kv"; and set args $args --data-urlencode "$kv"
    end

    set -l body (mktemp)
    set -l code
    for attempt in 1 2
        set code (curl -sS -G (_hn_base)"/$path" $args \
            --max-time (_hn_timeout) -o $body -w '%{http_code}' 2>/dev/null)
        if test $status -ne 0
            rm -f $body
            _hn_die "request failed (network or curl error) for /$path"
            return 1
        end
        # Retry once on throttling or a server blip; otherwise stop.
        if test "$code" = 429 -o "$code" -ge 500 2>/dev/null
            test $attempt -eq 1; and sleep 2; and continue
        end
        break
    end

    if test "$code" != 200
        set -l msg (jq -r '.error // .message // empty' <$body 2>/dev/null)
        rm -f $body
        test -z "$msg"; and set msg "HTTP $code"
        if test "$code" = 404
            _hn_die "not found ($msg) - check the id; deleted items are not in the index"
        else if test "$code" = 429
            _hn_die "rate limited ($msg) - slow down, or batch with a larger --limit"
        else
            _hn_die "$msg"
        end
        return 1
    end

    cat $body
    rm -f $body
end

# Run a jq program against stdin with hn.jq available via `include "hn";`.
function _hn_jq
    jq -L (status dirname) -r "include \"hn\"; $argv[1]"
end

# Algolia's typo tolerance is aggressive: an unquoted `elm` matches `Elon` and
# any URL containing "elm", which ruins date-sorted searches. Wrapping the
# query in double quotes turns it into an exact phrase and is almost always
# what research wants. --loose skips this.
function _hn_phrase
    set -l q "$argv[1]"
    if test -z "$q"
        echo ""
        return 0
    end
    # Leave alone if the caller already used quotes or Algolia's OR/NOT syntax.
    if string match -q '*"*' -- $q
        echo $q
    else
        echo "\"$q\""
    end
end

# YYYY-MM-DD (or anything `date -d` accepts) -> epoch seconds.
function _hn_epoch
    set -l e (date -d "$argv[1]" +%s 2>/dev/null)
    if test $status -ne 0; or test -z "$e"
        _hn_die "cannot parse date '$argv[1]' - use YYYY-MM-DD"
        return 1
    end
    echo $e
end

# Join numericFilters terms into the one comma-separated value Algolia wants.
function _hn_numeric
    set -l parts
    for p in $argv
        test -n "$p"; and set parts $parts $p
    end
    if test (count $parts) -gt 0
        echo "numericFilters="(string join ',' $parts)
    end
end

# Algolia caps any result set at 1000 hits, however you page through it.
set -g HN_MAX_HITS 1000
