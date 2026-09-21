# jq library for the hackernews scripts. Loaded with `jq -L <scripts-dir> 'include "hn"; ...'`.
#
# Keeping every regex in this file rather than in a fish string is deliberate: a
# backslash inside fish quotes has to survive fish, then JSON, then jq's regex
# parser, and the three disagree. Here it only has to survive jq.

# HN serves comment bodies as a small HTML subset with escaped entities.
# Order matters: &amp; decodes last, or "&amp;quot;" would decode twice.
def clean:
  (. // "")
  | gsub("<p>"; "\n\n")
  | gsub("<br\\s*/?>"; "\n")
  | gsub("<a[^>]*href=\"(?<u>[^\"]*)\"[^>]*>(?<t>[^<]*)</a>"; .u)
  | gsub("</?(i|b|em|strong|code|pre|span|div)[^>]*>"; "")
  | gsub("<[^>]+>"; "")
  | gsub("&#x2F;"; "/")
  | gsub("&#x27;"; "'")
  | gsub("&quot;"; "\"")
  | gsub("&gt;"; ">")
  | gsub("&lt;"; "<")
  | gsub("&#[0-9]+;"; "")
  | gsub("&amp;"; "&");

# One-line form: collapse all whitespace, then truncate.
def oneline($n): clean | gsub("\\s+"; " ") | ltrimstr(" ") | if length > $n then .[0:$n] + "…" else . end;

def ymd: (. // "")[0:10];
def epoch_ymd: if . == null then "?" else (. | strftime("%Y-%m-%d")) end;

def hn_url($id): "https://news.ycombinator.com/item?id=" + ($id | tostring);

# ---------------------------------------------------------------- search hits

# A story hit from /search or /search_by_date.
def story_line:
  "\(.created_at|ymd)  \(.points // 0 | tostring | (" " * (5 - length)) + .)p \(.num_comments // 0 | tostring | (" " * (5 - length)) + .)c  \(.title // .story_title // "(no title)")\n"
  + "         id \(.objectID)  by \(.author)"
  + (if .url then "\n         \(.url)" else "" end);

# A comment hit. story_title/story_id are denormalised onto comment records.
def comment_line:
  "\(.created_at|ymd)  \(.author)  on “\(.story_title // "?")” (story \(.story_id // "?"))\n"
  + "         id \(.objectID)  \(hn_url(.objectID))\n"
  + "         \(.comment_text | oneline(400))";

def hit_line:
  if (._tags // []) | index("comment") then comment_line else story_line end;

# ------------------------------------------------------------------ item tree

def item_header:
  "── \(.title // "(comment)")"
  + (if .url then "\n   \(.url)" else "" end)
  + "\n   \(.points // 0) points · \(.author // "?") · \(.created_at|ymd) · id \(.id)"
  + "\n   \(hn_url(.id))"
  + "\n   \([.. | objects | select(.type == "comment")] | length) comments in tree, \(.children | length) top-level\n";

# Flatten the reply tree depth-first, carrying depth, so fish can render it
# without recursing. Dead/deleted nodes carry a null author and no text.
def walk($depth; $maxdepth):
  if $maxdepth >= 0 and $depth > $maxdepth then empty
  else
    ( select(.author != null and (.text // "") != "")
      | { depth: $depth, id: .id, author: .author, created_at: .created_at,
          n_replies: (.children | length), text: (.text | clean) } ),
    (.children[]? | walk($depth + 1; $maxdepth))
  end;

def comments($maxdepth): .children[]? | walk(1; $maxdepth);

# Greedy word wrap of one source line to $w columns; $w <= 0 disables it.
def wrap($w):
  if $w <= 0 or (length <= $w) then [.]
  else
    reduce (splits("\\s+")) as $word ([];
      if length == 0 then [$word]
      elif ((.[-1] | length) + 1 + ($word | length)) <= $w then (.[0:-1] + [.[-1] + " " + $word])
      else (. + [$word]) end)
  end;

# One flattened comment record (from `comments`) as an indented block.
def comment_block($w):
  . as $c
  | (("  " * $c.depth) // "") as $ind
  | (if $w > 0 then ($w - ($c.depth * 2) - 2) else 0 end) as $tw
  | $ind + "▸ \($c.author)  ·  id \($c.id)  ·  \($c.created_at|ymd)"
      + (if $c.n_replies > 0 then "  ·  \($c.n_replies) " + (if $c.n_replies == 1 then "reply" else "replies" end) else "" end)
      + "\n"
  + ( $c.text
      | split("\n")
      | map(if (. | test("^\\s*$")) then "" else (wrap($tw) | map($ind + "  " + .) | join("\n")) end)
      | join("\n") )
  + "\n";
