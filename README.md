# The Reading Ledger

A front page for KOReader with pixel pets. Every book is a race between
**Biscuit the cat** (your place on this device) and **Pip the dog** (your place
in Readest, on your phone or tablet); the chequered flag is the last page.
Whoever is ahead shows you where to pick up: **Catch up with the dog** opens
the book and lets Readest move it forward to where you got to.

The front page also shows what you read today, your other books on the go,
what Pip fetched (new books nobody has opened yet), what Biscuit is waiting for
(books you requested through Bookbridge that haven't turned up), and either your
Hardcover shelves and yearly goal (paid in fish) or, without a Hardcover key,
what's trending on Open Library.

## Status

First working version (2026-10-04): front page, book page, the race, Catch up
with the dog, Open Library trending, Hardcover shelves and goal. Opened from
the main menu as **Reading Ledger** (or a gesture: "Reading Ledger").

Still to come: the onboarding screen, replacing Bookshelf as the home screen,
the Race results screen, and a run with the real Readest plugin signed in.

## Sources (all optional)

| Source | What it adds |
|---|---|
| This device | Books in progress, new arrivals, pages read today (KOReader statistics) |
| Readest plugin | Your position in Readest for every book (the dog) |
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
Catch up with the dog (opens the book and asks Readest to jump), the Ledger
over an open book, Library and Menu.

## Credits

- Cat sprites by **Shepardskin**, <https://opengameart.org/content/cat-sprites> (CC0)
- Dog sprites by **Jason of GDN**, <https://opengameart.org/content/dog-spritesheets> (CC0)
- Sprites converted to 16 e-ink greys and mirrored where needed; the fish was drawn for this plugin.
- Fonts: **Silkscreen** (Jason Kottke) and **Atkinson Hyperlegible** (Braille Institute),
  both SIL Open Font License; licence texts in `ledger.koplugin/fonts/`.
- Trending data from **Open Library** (Internet Archive).

---

Written 100% by an AI (Claude, by Anthropic), directed by Matt. Read it before
you trust it.
