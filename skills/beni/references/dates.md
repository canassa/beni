# Dates: `Date`

`Date` is core, on every platform. A moment is a `Date.Posix`; a page's `Time.Posix` is the same
type.

- `Date.fromIso8601 text` parses an RFC 3339 date or date-time, as `2016-02-18T03:22:56.637Z`.
  Any other text, and a field out of its range, is `Nothing`. It never calls the host's
  `Date.parse`.
- `Date.toIso8601 t` writes the moment in UTC, as `Date.prototype.toISOString` writes it.
- A zone is `Date.utc` or a name of the host's time zone database: `Date.named "Europe/Berlin"`
  is a `Maybe Zone`, and `Date.here ⊤` is the reader's zone (impure). A zone is never a fixed
  offset, so a date on either side of a daylight saving change is correct. A name in any case and
  an old link give one zone, by the host's canonical name; an offset as `"+01:00"` is `Nothing`.
- `Date.toParts t zone` gives `year`, `month` (a `Month`: `Jan` … `Dec`), `day`, `weekday`
  (`Mon` … `Sun`), `hour`, `minute`, `second`, `millis` and `offset` (minutes east of UTC).
- There are no month names. Write the words of your language for `Month` yourself.

Get the zone once, where the program starts (`init`), and keep it in the model. Each call of
`Date.here` or `Date.named` makes a new formatter of the host, and a zone that is kept makes none.

```beni
import Date


pub year : Date.Zone, String → Maybe Int
year zone text = Maybe.map (Date.fromIso8601 text) λt → (Date.toParts t zone).year
```

Sources: `docs/design/boundary.md` §9.8.21; `core/Date.beni`; `platforms/browser/Time.beni`.
