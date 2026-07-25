# PitchIQ

A Fantasy Premier League assistant for iOS. It projects every player's score for
every remaining gameweek, picks the squad that maximises those projections under
the real rules, and tells you what to do with the team you already own.

Native SwiftUI, no dependencies. Data comes from the public FPL API — no login,
no key.

```
xcodegen generate
xcodebuild -scheme PitchIQ -destination 'generic/platform=iOS' -configuration Debug build
```

---

## What it does

**Team** — the season plan. Every gameweek from now to GW38 carries one
instruction ("roll the transfer", "Sonny → Saka", "Bench Boost — all 15 score"),
the eleven to field that week, and the reasoning. Chips are scheduled only where
they earn their keep.

**Transfers** — the workbench, all relative to your fifteen:
* every legal single move ranked by points gained over the rest of the season
* the best *pair* of moves, with an explicit verdict on whether a −4 pays back
* a squad audit: injuries, players you're paying to sit on a bench, blank
  gameweeks, triple-ups, idle bank, a bench too thin for a Bench Boost
* price-change watch, differentials, and points-per-£m

**Players** — every player ranked by projection, value, ceiling, form or
ownership, with the fixture run beside them.

**Captain** — candidates with the shape of their week, not just the average:
ceiling, chance of a haul, chance of a blank, and effective ownership.

**Fixtures** — the ticker, ranked by the model's own attack and defence ratings
in expected goals rather than FPL's 1-5 badge, with separate views for what
attackers want and what defenders want.

### Connect your team

Settings → paste your FPL team ID (the number in
`fantasy.premierleague.com/entry/**1234567**/event/1`). Every screen then works
from your actual fifteen, bank, free transfers and remaining chips. The endpoints
are public; FPL publishes picks once a gameweek deadline has passed, so the
import reports a readable message rather than an error before the season starts.

---

## How the numbers are made

### Projection (`Engine.swift`)

Per player per fixture, built from FPL's scoring rules rather than fitted to
points totals:

| Component | Source |
|---|---|
| Appearance | P(start) and P(60') from `starts`, not minutes alone |
| Goals | xG/90 blended with finishing, × position value, × fixture |
| Assists | xA/90 converted into FPL-assist units, set-piece duty applied |
| Clean sheet | negative binomial on opponent xG, not Poisson — real goals-against are over-dispersed, and Poisson under-counted shut-outs by ~15% |
| Conceded | exact E⌊goals/2⌋ |
| Saves | exact E⌊saves/3⌋ — FPL pays in whole blocks of three |
| Defensive contribution | Poisson tail above the CBIT/CBIRT threshold |
| Bonus, cards | realised rates shrunk to positional priors |

That model is blended with the player's own scoring history and with FPL's
`ep_next`, weighted by a smooth credibility term in minutes played.

Fixture strength comes from per-club attack and defence ratings in expected goals
per match, credibility-shrunk toward the league mean, with FPL's difficulty
rating kept only as a stabiliser and as the sole signal for promoted clubs.

The next gameweek is also convolved into a full distribution — goals, assists and
clean sheet enumerated, appearance modelled as three states (didn't play, came
off the bench, started) — which is where ceiling, haul% and blank% come from.

### Squad selection (`Solver.swift`)

Maximises `best XI + captain + 0.12 × bench` subject to £100m, 2/5/5/3 and
max-three-per-club, in three stages:

1. **An exact dynamic program over cost.** Because the captain is always the
   highest-projected player in his own position, enumerating which of the four
   positions holds the captain turns the captain bonus into a fixed weight on
   that position's top starter. Maximised over the four enumerations and the
   eight formations, the DP is a true optimum of the full objective for the
   problem relaxed of the club limit. No sampling, no randomness.
2. **Club-limit repair** by minimum-loss substitution.
3. **Steepest-descent local search** under the exact objective with the club
   limit enforced, over single swaps and budget-funded double swaps.

The candidate pool is pruned by dominance first: a player is dropped only when at
least `quota` others in his position cost no more *and* project at least as high,
at which point one dominator is always spare. That is lossless and takes ~512
selectable players down to ~81, which is what makes the exact DP cheap.

Verified on live data:

```
pool: 512 → 81 after dominance pruning
full pool 353.4619 vs reduced pool 353.4619        pruning costs nothing
cost £100.0m | quota 1:2 2:5 3:5 4:3 | max/club 2  all constraints hold
3622 random legal squads: best 336.77 vs 353.46    never beaten
same squad regardless of pool order                fully deterministic
```

**Why this replaced simulated annealing.** The old solver searched a rugged
objective from a random start, so it settled in a different local optimum
whenever a single price ticked. Measured against live data, one day of ordinary
price movement rewrote four or five of the fifteen — which is why the app used to
show a different team on every visit. The solver is now a pure function of its
input, is seeded from the squad already on screen, and only replaces it when a
new squad wins by a real margin. Same data in, same team out.

### Season plan (`Planner.swift`)

Simulates every remaining gameweek under the real rules: one free transfer a week
banking to five, −4 per extra, a fixed budget, injuries prioritised.

* **Free transfers are priced, not guessed.** A banked transfer has option value —
  it buys the right to react to next week's news — and that value collapses to
  zero at the cap of five, where an unused one is simply lost. The bar a move has
  to clear falls with it.
* **Chips have to earn their place.** Triple Captain and Bench Boost are tested
  against the *median* week in their window, not an absolute number, so a chip
  isn't burned in GW2 just because a captain projects six points. As a deadline
  approaches the bar falls away, because using a chip beats losing it — and the
  plan says which of the two happened.
* **Free Hit is held for a double gameweek** and only falls back to a normal week
  when its window is closing. Doubles are announced mid-season, and the plan
  re-runs on every refresh.

### Speed

Measured end to end on the full 2026/27 dataset:

```
read + decode JSON (1.3 MB)      28.2 ms
build projection engine           0.3 ms
project 558 players × 38 GW       2.1 ms
solve optimal XV                  3.1 ms
plan 38 gameweeks + chips        40.4 ms
all decision tools                8.8 ms
```

The launch itself is faster than any of that suggests: the app renders from its
on-disk cache immediately and only touches the network when the cache is more
than fifteen minutes old. Recomputation happens on a background task and leaves
the previous answer on screen, so changing a setting no longer replaces the team
with a spinner.

---

## Layout

```
Sources/
  Engine.swift        projections, team ratings, score distributions
  Solver.swift        exact DP + local search squad selection
  Optimizer.swift     XI evaluation, constraints, entry point
  Planner.swift       season simulation, transfers, chip scheduling
  Advisor.swift       transfer board, captaincy, market, squad audit
  AppState.swift      loading, caching, persistence, team connection
  DataCache.swift     FPL API + on-disk payload cache
  FPLModels.swift     API payloads and derived types
  Views/              Team · Transfers · Players · Captain · Fixtures
```

### Testing the engine without a simulator

Every file above except `AppState`, `Theme` and `Views/` is Foundation-only, so
the model can be compiled and run headlessly against cached JSON:

```bash
swiftc -O -o bench main.swift \
  Sources/{Engine,Optimizer,Solver,Planner,Advisor,FPLModels}.swift
```

### Gotcha

FPL's pre-season bootstrap carries last season's player stats but zeroes the team
strength fields. Use fixture `team_h_difficulty` / `team_a_difficulty` for
difficulty, never the team strength ratings.
