# Changelog

### v0.7.0

First feature-complete build. A player-driven flea market backed by a server,
with real prices, physical cash and physical delivery.

Added
- **Terminal and courier crate**, both placeable furniture. Position them
  anywhere in your shelter from the decor menu; the game keeps them there.
- **Browse** with search, category and sort, and a market indicator showing
  whether each price is below, at or above the 7-day average.
- **Item detail** with price history, recent sales, 24-hour volume, broker
  bid/ask, delivery time and the all-in total.
- **Sell** — list at your own price, or sell outright to the broker for
  instant cash. The listing fee, the commission and your net proceeds are all
  shown before you commit.
- **Buy** — purchases arrive in the courier crate after a real-time delay.
- **My orders** — your standing listings with countdowns, and inbound
  deliveries. Listings can be cancelled.
- **Wallet** — server-held credit, and withdrawing it as physical cash.

Notes
- Requires the Cash System mod: fees and payments are physical cash.
- You need a player key, pasted into the terminal's Setup screen once.
- The terminal and crate currently render as placeholder boxes.
- Buy orders / wanted ads are not in this release.

Safety
- Nothing you own can be lost to a crash, a timeout or a lost connection.
  Every trade is recorded before anything is destroyed, and finishes itself
  the next time you open the terminal.
- A full courier crate is not an error: deliveries wait on the van until you
  clear space.
- Containers with something inside them cannot be sold, because selling one
  would destroy its contents.
