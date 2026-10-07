# The Reading Ledger

A front page for KOReader with pixel pets, where every book is a race. Pick
your runner -- cat, dog, rabbit or tortoise -- and a rival. The rival learns
your reading habits from KOReader's statistics (the last 8 weeks) and races
you on them:

- **How much it reads:** what you usually read on that day of the week,
  nudged by whether you've been reading more or less lately.
- **When it reads:** at the hours you usually read, so it doesn't run off in
  the morning if you only read at night.
- **How hard it is:** every day it checks whether you read more than it did
  over the week before, and tunes itself so you're ahead about as often as
  its animal says:

  | Rival | You're ahead |
  |---|---|
  | Tortoise | most of the time (easy) |
  | Cat | about 2 weeks in 3 (fair) |
  | Dog | about half the time (hard) |
  | Rabbit | about half, but streaky: fast, and naps every third day |

- **Keeping it close:** in a book, a rival a few days ahead of you eases off
  and one far behind pushes, so it stays a race -- but either of you can win.

Settings shows what the rival has learned (your typical day, best weekday,
usual hours, how often you've been ahead). With no statistics yet it assumes
about 20 pages a day until it has a few days to go on.

Pass the rival before the chequered flag (the last page) to win the book;
out-read its share each day to win the day. A dead heat goes to you.

**The same race on every device.** Nothing about the race is stored on a
device: it is rebuilt from KOReader's reading statistics, which Bookbridge
keeps in step between your devices through Readest. Each day is decided
only by the reading before it, so your phone and your Kindle show the same
rival, the same days won and the same books won -- whichever you look at,
and whenever. A book's race starts at your first page turn in it (and again
where you pick it up after a two-week break). Settings > Books > **Sync now
with my other devices** catches up on the spot.

**Reading in Readest counts.** Your place in a book is the furthest of this
device and Readest, and pages you read in Readest on your phone, tablet or
computer count toward today, this week and what the rival learns. When the
Ledger opens it asks the Readest plugin to pull its reading statistics and
library positions in the background, and redraws when they land. Pages
counted from a book moving on in Readest are taken off again if the same
stretch arrives through the statistics sync, so nothing counts twice. When Readest is
further on, two buttons say exactly where each opens: **Continue from p. 203**
(where you got to in Readest) or **Stay on p. 181** (where this device is).

The front page also shows what you read today, your other books on the go,
new arrivals nobody has opened yet, books you requested through Bookbridge
that haven't turned up, and your Hardcover yearly goal (paid in fish). The
Library has a **Trending** shelf: this week's most-read books on Open Library,
marked when they're already on the device; tap one to open it, or to request
it through Bookbridge.

## Status

Three pages, switched by a tab bar at the bottom (2026-10-04):

- **Currently reading** (the main page, the middle tab): the book you're on -- big cover, title, series,
  pages and time left (from your own pace in KOReader's statistics), the
  description (tap for all of it), and the **race**: you on the ground, your
  rival on the lane above, a chequered flag and a fish at the finish. They
  sprint in from the start line when the page opens (a napping rabbit lies
  still under a Z); tap either runner or the fish and they tell you where
  they are. A line for today's race, today / this week / streak, new arrivals
  and what's on order, the yearly goal in fish.
  Several books on the go: swipe or tap < > to switch.
- **What's next in a series**: finish a book and, under "You finished...",
  the next one in its series -- from Hardcover with your key (the series in
  order, skipping the ones you've read there), otherwise from the books' own
  series and number on this device. Tap: the book, or Bookbridge to get it.
- **Friends** (Settings): race up to three people you follow on Hardcover.
  When one of them is reading the book you're reading, they're your rival in
  it -- their animal, at their place from Hardcover. Every week, pages read:
  "This week: you 212 · alex 180". You see what their Hardcover privacy shows
  followers; your progress reaches them the same way (Bookbridge sends it).
  Needs your Hardcover key.
- **Your year** (tap today / this week / streak): pages, books, days read and
  hours; your best streak, biggest day, the race record and the quickest book;
  pages month by month and the books you finished -- from the statistics, so
  every device shows the same year. < > for earlier years.
- **Library**: every book on the device as a paged grid of covers (tap to
  open, hold for its page), filters and sort, and behind **More**: Trending
  (Open Library this week), Want to read (your Hardcover shelf) and Requested
  (asked for through Bookbridge, not here yet). Files for KOReader's own
  browser. (Status bars are still being chosen.)
- **Settings**: your runner and your rival (and their names), what the rival
  has learned about your reading, Hardcover key, Readest and Bookbridge status,
  animations on/off, refresh, about and credits.

**Setting up.** The first time it opens, four short steps: pick your
runner, pick your rival, see what's switched on (reading statistics,
Readest, Bookbridge, Hardcover -- with a button where it can be fixed from
there), and whether the Ledger should be your home screen: then it opens
when KOReader starts and every time you close a book, with Files one tap
away. Settings has all of it again.

**Results.** A finished book's race gets a result: in the Library its
status says WON or LOST, its page says by how much, and Currently reading
keeps your record against the rival.

Still to come: library progress bars (style still being chosen), and a run
on a real Kindle.

## Install

Two ways, both from the [releases](https://github.com/TheFactor1/koreader-reading-ledger/releases):

- **Already have [Bookbridge](https://github.com/TheFactor1/koreader-bookbridge-plugin)
  (v0.8.1 or later)?** Bookbridge > Status & setup > *Reading Ledger -- home
  screen* > Install. It downloads `reading-ledger-<version>.koplugin.zip`
  from the release, checks it against GitHub's checksum, and asks to restart.
- **Starting from nothing:** download `reading-ledger-<version>.zip` -- the
  bundle with two folders, `ledger.koplugin` and `bookbridge.koplugin` --
  and copy both into KOReader's `plugins` folder (on a Kindle,
  `/mnt/us/koreader/plugins/`), then restart KOReader.

Open it from Tools > Reading Ledger, or pick "reading ledger" in Settings >
Start with; the first time it walks you through setting up -- **Readest
first**: a free Readest account keeps your library, your place in each book
and your reading (so your race) the same on every device.

**Updates:** Settings > Check for updates in the Ledger, or let Bookbridge do
it -- the Ledger is one of its companions, kept current together with the
Z-Library and Readest plugins, with the previous version kept for a rollback.

Building the downloads yourself: `tools/make-release.sh` (the Ledger alone,
what Bookbridge installs) and `tools/make-bundle.sh` (Ledger + Bookbridge).

**Bookbridge lives inside the Ledger.** It's still its own plugin in its own
folder -- it updates itself, and works without the Ledger -- but with the
Ledger installed it's reached from there: Settings > Bookbridge opens its
whole menu (sign-in, search and request, requests, Calibre-Web sync,
Hardcover, its settings), and the Library's FIND button is its search. Its
entry in KOReader's own menu is tucked away; "In KOReader's menu too" at the
bottom of that menu brings it back.

## Sources (all optional)

| Source | What it adds |
|---|---|
| This device | Books in progress, new arrivals, pages read today (KOReader statistics) |
| Readest plugin | Your position in Readest for every book, and reading done there (statistics and positions) |
| Bookbridge | Requests still on order, Hardcover matches, search and request |
| Hardcover, your own key | Shelves, yearly goal, a book's rating and series, what's next in a series, friends' reading |
| Open Library | The Trending shelf, and a cover for a book that has none of its own (looked up once by its title and author); no account, straight from the device |

No server of anyone's is involved for trending, and no shared Hardcover key is
built in: a Hardcover key is a personal account token.

## Tested

On the desktop KOReader v2026.07.1 in a throwaway `KO_HOME` (Paperwhite-sized
1072x1448 at 300 dpi, and 600x800), with real EPUBs and covers, a Readest
library, reading statistics and seeded Hardcover numbers; taps injected as real
KOReader gestures. Covered: front page with and without a Hardcover key (Open
Library fetched live), book page for a book in progress and a new arrival,
Continue from Readest's page (opens the book and asks Readest to jump), the Ledger
over an open book, Library and Menu; the library's filters, sort, paging, opening a book from the
grid and back, and Files, with 20 books (some in a subfolder).

## Credits

- Cat sprites by **Shepardskin**, <https://opengameart.org/content/cat-sprites> (CC0)
- Dog sprites by **Jason of GDN**, <https://opengameart.org/content/dog-spritesheets> (CC0)
- Rabbit sprites by **ScratchIO**, <https://opengameart.org/content/animated-wild-animals> (CC0)
- Tortoise sprites by **Sogomn**, <https://opengameart.org/content/animated-turtle> (CC0)
- Sprites converted to 16 e-ink greys and mirrored where needed; the fish was drawn for this plugin.
- Fonts: **Silkscreen** (Jason Kottke) and **Atkinson Hyperlegible** (Braille Institute),
  both SIL Open Font License; licence texts in `ledger.koplugin/fonts/`.
- Trending data from **Open Library** (Internet Archive).
- Installed and updated by **Bookbridge** (same author), whose menu it wraps.

## License

AGPL-3.0 (see `LICENSE`), like Bookbridge and KOReader. The sprites are CC0
and the fonts SIL OFL, as credited above.

---

Written 100% by an AI (Claude, by Anthropic), directed by Matt. Read it before
you trust it.
