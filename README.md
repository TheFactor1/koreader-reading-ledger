# The Reading Ledger

A front page for KOReader with pixel pets, where every book is a race. Pick
your runner -- cat, dog, rabbit or tortoise -- and a rival. The rival starts
the book when you do and reads a set number of pages a day, based on how much
you usually read (KOReader's statistics):

| Rival | Reads |
|---|---|
| Tortoise | what you usually read |
| Cat | about 15% more |
| Dog | about 30% more |
| Rabbit | twice as much, but naps every third day |

Pass it before the chequered flag (the last page) to win the book, and
out-read its share each day to win the day. Your place is the furthest of
this device and Readest, so pages read on your phone count. When Readest is
further on, two buttons say exactly where each opens: **Continue from p. 203**
(where you got to in Readest) or **Stay on p. 181** (where this device is).

The front page also shows what you read today, your other books on the go,
new arrivals nobody has opened yet, books you requested through Bookbridge
that haven't turned up, and either your Hardcover shelves and yearly goal
(paid in fish) or, without a Hardcover key, what's trending on Open Library.

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
- **Library**: every book on the device as a paged grid of covers, filters and
  sort, Files for KOReader's own browser. (Status bars are still being chosen.)
- **Settings**: your runner and your rival (and their names), Hardcover key, Readest and Bookbridge status,
  animations on/off, refresh, about and credits.

Still to come: progress bars in the library, onboarding, replacing Bookshelf
as the home screen, the Race results screen, and a run with the real Readest
plugin signed in.

## Sources (all optional)

| Source | What it adds |
|---|---|
| This device | Books in progress, new arrivals, pages read today (KOReader statistics) |
| Readest plugin | Your position in Readest for every book (it counts toward your place in the race) |
| Bookbridge | Requests still on order, Hardcover matches, search and request |
| Hardcover, your own key | Shelves, yearly goal, a book's rating and series |
| Open Library | Trending books when there's no Hardcover key; no account, straight from the device |

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

---

Written 100% by an AI (Claude, by Anthropic), directed by Matt. Read it before
you trust it.
