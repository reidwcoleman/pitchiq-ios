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

**Live** — the gameweek as it happens. Your eleven with points as they are
scored, the bonus FPL has not awarded yet worked out from live BPS, who is still
to play, the substitutions that will be made at full time, your mini-league
places and every score in the round. It polls once a minute while matches are on
and not at all when they aren't.

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
attackers want and what defenders want. Shares the Players tab, because iOS only
gives five tabs before it starts hiding screens behind a More button.

The deadline counts down in the header of every screen.

### Connect your team

Settings → paste your FPL team ID (the number in
`fantasy.premierleague.com/entry/**1234567**/event/1`). Every screen then works
from your actual fifteen, bank, free transfers and remaining chips. The endpoints
are public; FPL publishes picks once a gameweek deadline has passed, so the
import reports a readable message rather than an error before the season starts.

---

## How the numbers are made

### The prior season (`History.swift`)

The hardest week to project anything is the first one, and it is also the week
that decides the most transfers. After one gameweek FPL's feed said Haaland had
scored two points off ninety minutes at 0.85 expected goals; a model that trusts
only the current season shrinks him toward a generic forward, and this app duly
projected him at 2.6 a week and ranked a full-back above him.

FPL publishes every player's per-season totals at `element-summary/{id}/` —
minutes, starts, expected goals, expected assists, expected goals conceded, BPS,
bonus, cards, saves — back to 2022/23. Those seasons become the prior, weighted
by recency (1, 0.45, 0.18) and folded into the current season's totals as
pseudo-observations:

```
lam    = 900 / (900 + minutes played this season)   // all of it in August,
pMin   = min(prior minutes, 2600) · lam             // half after ten matches
rate   = (this season's total + prior total · pMin/prior minutes) / (minutes + pMin) · 90
```

One idea, applied to goals, assists, bonus, BPS, cards, saves, defensive
contributions, expected goals conceded and minutes alike. This season's numbers
are evidence *against* the prior rather than a replacement for it, and by
November they have overwhelmed it without a single hard cut-over. 600 small
requests, cached on disk for a week, since finished seasons do not change.

### How many matches the totals cover

Every per-match rate divides by this, and it used to be the count of events
FPL had marked `finished` — which is zero from the moment a gameweek's first
match kicks off until every fixture in it has been verified, and 38 in
pre-season, when the feed carries last season's totals. Divide one match of
data by 38 and the whole league projects at a quarter of its true rate.

It is now read off the data: the busiest player in the league plays one match a
gameweek, so his minutes divided by 90 is the number of gameweeks the totals
cover. In pre-season it lands on 38 by itself.

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
| Bonus | realised rate, blended with a BPS estimate, shrunk to a positional prior |
| Cards | realised yellow/red rates |
| Form | the 30-day average against the season level, applied to goals, assists and bonus |

That model is blended with the player's own scoring history and with FPL's
`ep_next`, weighted by a smooth credibility term in minutes played.

**Independent measurement channels.** FPL publishes threat, creativity and BPS
indices built from different inputs than the expected-goals feed — shot location
and volume, chances created, the full bonus rubric — so they carry information xG
does not. Coefficients are fitted by least squares through the origin against
every player with 900+ minutes in the source data, which means folding them in
re-ranks players without moving the population mean:

| Channel | | r (DEF / MID / FWD) |
|---|---|---|
| threat / 90 | → xG / 90 | 0.77 · 0.83 · 0.78 |
| creativity / 90 | → xA / 90 | 0.86 · 0.88 · 0.73 |
| bps / 90 | → bonus / 90 | 0.65 · 0.72 · 0.88 |

Keepers are excluded from the BPS channel: their BPS barely predicts their bonus
(r = 0.19).

**Form** is points per match over the last 30 days; points per game is the
season-long level. Their ratio is the trend, applied to the parts of a projection
that genuinely move with a player's run of touch — goals, assists, bonus — and not
to appearance points or his team's clean-sheet odds. The weight (0.4, clamped to
0.72–1.45) is deliberately well under 1: four matches is a small sample and
chasing it is the standard way to lose a season, but ignoring a player who has
changed role or started taking the penalties throws away the freshest information
available. Measured effect: doubling every player's form lifts projections by a
median 17%. Form reads 0.0 for everyone until matches are played, so it is inert
in pre-season by design.

**Squad status** blends start rate, starts per 90 minutes played and minutes per
appearance into one number. Two players can share a start rate and not share a
role — one plays 90 every week, the other is hooked on the hour.

**A defender's own record.** Team ratings come from the keeper's expected goals
conceded, but a defender's own xGC/90 measures what the team conceded *while he
was on the pitch*, which tracks goals actually conceded at r = 0.71. It is applied
as a multiplier on the fixture's concession rate — for a Poisson clean sheet
P(0) = e^-λ, so scaling λ by s is exactly P(0)^s.

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
full pool 348.8713 vs reduced pool 348.8713        pruning costs nothing
cost £100.0m | quota 1:2 2:5 3:5 4:3 | max/club 3  all constraints hold
3598 random legal squads: best 333.42 vs 348.87    never beaten
same squad regardless of pool order                fully deterministic
```

**Why this replaced simulated annealing.** The old solver searched a rugged
objective from a random start, so it settled in a different local optimum
whenever a single price ticked. Measured against live data, one day of ordinary
price movement rewrote four or five of the fifteen — which is why the app used to
show a different team on every visit. The solver is now a pure function of its
input, is seeded from the squad already on screen, and only replaces it when a
new squad wins by a real margin:

```
day of price moves    unanchored    anchored
1                     15/15 kept    15/15 kept
2                     13/15 kept    15/15 kept
3                     15/15 kept    15/15 kept
4                     13/15 kept    15/15 kept
```

### Valuing a player for the rest of the season

Squad selection needs one number per player: what he is worth to hold. Three
things trade off.

* **Points now** — the nearest gameweeks are the ones you are certain to play him
  for, so they carry a premium.
* **Points later** — the weight decays toward a floor, not toward zero. The
  previous version used a flat 0.88 geometric decay, which put GW25 at 4% of GW1,
  so "best squad" quietly meant "best squad for about eight gameweeks".
* **Whether he will still be playing** — a projection for April is worth what it
  says only if the player still starts in April, so far gameweeks are discounted
  by squad status. That term alone changes 3 of 15 picks.

Rather than trust one hand-picked discount rate, the planner builds a squad under
each of three profiles — *Next six*, *Balanced*, *Whole season* — and **plays each
one through every remaining gameweek**, transfers, chips, injuries and blanks
included, keeping whichever actually scores most. The proxies are guesses; the
simulation is the real objective. The squad already on screen is scored on the
same scale and keeps its place unless beaten by 12 season points.

**An honest caveat.** On a full 38-gameweek horizon the three profiles land within
0.2% of each other and rank players at Spearman 0.998+. That is a real property of
the competition, not a bug: over a whole season every club plays everyone home and
away, so fixture advantage averages out — the gameweek-to-gameweek spread of a
regular starter's projection is ~9% over six gameweeks and ~9% over thirty-eight.
The machinery earns its keep later in the season, when the remaining run is short
enough for fixtures to genuinely diverge, and when form and injuries have pulled
players apart. At GW1 it mostly confirms that the near-term and season-long
answers agree.

### What a transfer is worth

A transfer's gain is the change in **what the squad actually scores** — best XI,
captain doubled, plus a tenth of the bench — summed over the next **four**
gameweeks with a 0.80 discount.

It is not the change in the incoming player's own projection, which is what this
measured until recently. By that standard, replacing the fourth-choice forward
who never leaves your bench with a slightly better fourth-choice forward scored
exactly as well as the same upgrade to a starter, and the planner duly spent free
transfers on players who could not earn it a single point. Bench points only
count through auto-substitutions and Bench Boost, hence the tenth rather than
zero.

Two guards sit on top:

**A floor.** A move must add at least 0.10 points to the eleven to be worth
making, however many free transfers are spare. "Free" is not "costless" — the
transfer you spend is the one you wanted next week. Swept against a full season:

```
floor  transfers  →XI  →bench   season pts   pts per transfer
0.00          28   18      10       2164.5           +0.21
0.05          20   16       4       2163.9           +0.27
0.10           9    8       1       2161.7           +0.36
0.20           4    4       0       2159.4           +0.23
0.30           1    1       0       2158.6           +0.05
```

With no floor the planner makes 28 transfers a season, ten of them on players who
never leave the bench, for 0.21 points each. At 0.10 it makes nine, eight of which
walk straight into the eleven, and earns nearly twice as much per move — giving up
2.8 points that were being chased through model noise, since no projection is
accurate to a twentieth of a point.

**A short holding period.** Selling a player bought within *two* gameweeks, or
buying one back that recently, costs 0.4 points. It only covers immediate
reversals: selling a player whose next four fixtures are ugly and buying him back
when they turn is a real strategy, not churn. A six-gameweek holding period
blocked exactly that rotation and cost points doing it.

### Why the window is four gameweeks

The right horizon for a transfer is not "the rest of the season" — it is *until
you would transfer again*. Scoring a move over twelve gameweeks silently assumes
you hold the player for twelve, which is wrong for anyone who uses their free
transfer most weeks: it averages a good run and a bad run together and concludes
nothing is worth doing.

The numbers behind that: a single fixture moves a regular starter's projection by
about 55% (Haaland at home to a promoted side against Haaland away at Arsenal).
But over a *six-gameweek run* the best-to-worst gap collapses to 11%, because runs
even out. Judge a transfer over twelve weeks and there is nothing left to see.

```
lookahead  decay  transfers  →XI  →bench   season pts
       12   0.88         10   10       0       2160.6
        8   0.86         13   12       1       2161.5
        6   0.85         32   25       7       2166.7
        4   0.80         29   27       2       2169.1
```

Four is both the most active *and* the highest scoring. The shorter window is not
a trade-off against accuracy — it is a better model of how the team is actually
managed. The season plan now makes ~28 transfers, nearly all of them straight
into the starting eleven, rotating players out when their run turns and back in
when it improves.

Verified against a squad whose starters lose their form mid-season: all three go,
worst first, at +2.44, +1.11 and +1.38 points to the eleven.

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
plan 38 gameweeks + chips       117.5 ms
all decision tools                2.4 ms
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
  History.swift       prior-season digests: fetch, cache, recency-weighting
  Live.swift          live points, provisional bonus, auto-subs, standings
  Images.swift        player photographs and club crests, cached twice
  Views/              Live · Team · Transfers · Players+Fixtures · Captain
```

## Is it any good?

Nothing below is an opinion. Everything the model does that could be measured,
was, and two ideas that seemed obviously right were measured, found to lose
points, and thrown away.

### Replaying finished seasons (`Tools/`, `bench --eval`)

FPL publishes per-season totals back to 2022/23, which is as far back as
expected goals go. So the model can be handed everything up to the end of one
season — with every current-season number, including FPL's own `ep_next`,
blanked — and asked about the next one. Three seasons can be replayed that way.

| | before | after |
|---|---|---|
| rank correlation (Spearman) | 0.453 | 0.457 |
| points held by the fifty players it liked most | 76% | 77% |
| actual points of a £100m fifteen picked on its ranking | 1583 | 1596 |

For scale: picking on last season's points alone scores about 1360, picking the
most expensive squad you can afford about 1300, and perfect hindsight 2050.

### Where the error is (`bench --diagnose`)

This is the number that decided what to work on. Give the model the *real*
minutes each player went on to play, and its scoring rates explain almost
everything:

| season | as shipped | with perfect minutes | with perfect rates |
|---|---|---|---|
| 2023/24 | r 0.49 | **r 0.85** | r 0.64 |
| 2024/25 | r 0.51 | **r 0.90** | r 0.50 |
| 2025/26 | r 0.41 | **r 0.85** | r 0.47 |

The rate model is close to the ceiling. Essentially all the remaining error is
in predicting who plays — which is why the minutes model gets its own recency
profile, its own evidence-weighted shrinkage, and the last six gameweeks read
straight from the live feed.

### Fitting the constants (`bench --sweep`, `bench --tune --cv`)

Coordinate descent over a dozen constants on three seasons finds something; the
question is whether what it finds is real. Leave-one-season-out says the honest
gain from fitting on top of the shipped values is under one percent, and the
seasons disagree about most knobs. So the constants are swept one at a time with
every season shown separately, and only changes that move all three the same way
are kept. Three did:

* **minutes carry their own recency.** Scoring rates are stable and take three
  seasons; minutes take barely one. Splitting them was the largest single gain.
* **seasons are weighted by how long ago they were**, not by their position in a
  list — a player who missed a year has a "last season" that is two years old.
* **the history anchor beats the rate model when there is nothing but last
  season to go on.** Points per appearance quietly knows the things the
  component model can't see: role, team quality, who takes the penalties. So the
  rate model earns its weight as real minutes accumulate instead of being handed
  it.

An age penalty on scoring rates looked like a consistent winner right up until
the anchor was reweighted, after which the fitter stopped reaching for it —
it had been standing in for what the anchor already knew. It isn't in the model.

### Simulating seasons to test decisions (`bench --policy`)

Forecasts can be checked against history. Decisions can't: there is no record of
what a squad would have scored had it been managed differently. So the decision
layer is tested against drawn seasons instead — the model's own projections as
the truth, plus the two things that make managing hard, players who don't turn up
and players who get injured for weeks. Every policy sees the same draws, so a
difference in final points is a difference in decision quality.

Over 500 simulated seasons, starting from a squad that needs work:

| | points |
|---|---|
| the old rules (4-gameweek view, −4 bar of 6) | 2185 |
| **the rules now (6-gameweek view, −4 bar of 4.5)** | **2191** (+5.7 ± 4.2) |
| never take a hit | 2181 (−4.2) |
| at most one transfer a week | 2179 (−6.9) |

**Two things were tried and rejected.** Judging transfers over one gameweek
instead of six costs fifty points a season. And a search for the best *pair* of
transfers — including the classic downgrade-to-fund-an-upgrade, which the app
genuinely could not see before — turns out to *lose* points when the planner is
allowed to act on it, at every threshold tested, because spending two transfers
this week burns the banked one that next week's injury list would have spent
better. The search is still there and still shown to you; the planner just
doesn't take pairs on its own.

### Testing the engine without a simulator

Every file above except `AppState`, `Theme` and `Views/` is Foundation-only, so
the model can be compiled and run headlessly against cached JSON:

```bash
swiftc -O -o bench main.swift eval.swift \
  Tools/{Simulate,PolicyBench}.swift \
  Sources/{Engine,Optimizer,Solver,Planner,Advisor,FPLModels,History,Live,DataCache}.swift
```

| command | what it answers |
|---|---|
| `bench --eval` | how well did it predict each replayable season |
| `bench --diagnose` | is the error in the rates or in the minutes |
| `bench --sweep` | what does each constant do, season by season |
| `bench --tune --cv` | does fitting them generalise, or is it noise |
| `bench --policy` | does a change to the decision rules win points |
| `bench --why <name>` | where one player's projection came from, line by line |

`--why` is the one to reach for first when a projection looks wrong. It prints
the minutes model, the history anchor and every component of the rate model side
by side, which is how the form bug below was found:

```
Haaland  (pos 4, £15.5m)
  this season   90 mins, 1 starts, 2 pts
  2025/26       2953 mins, 34 starts, 239 pts  (7.28 per 90)
  minutes model  pPlay 0.95  p60 0.83  minShare 0.87 (78 mins/match)
  anchor         6.38 pts per appearance × 0.95 = 6.03 per gameweek
  rate model     appearance 1.78  goals 2.14  assists 0.29  bonus 0.76
  blend          model 4.92 × 0.35  +  anchor 5.59 × 0.65  →  5.35
```

The calibration check worth running after any engine change is the league-wide
total: summing every player's projection for one gameweek should land near
**1000**, which is what a real gameweek pays out across all 609 players. It
currently reads 939 (GK 101 · DEF 305 · MID 421 · FWD 113).

### Gotchas

**Team strengths are always zero.** `strength_attack_home` and friends read 0 for
all twenty clubs in pre-season *and* through the opening weeks, so they cannot
seed anything. The fixture list can: the difficulty FPL assigns to a club's
opponents, averaged over all 38 matches, is its own season-long verdict on that
club, and it separates Manchester City (4.50) from Coventry (2.00) before a ball
is kicked. `TeamRatings.seedStrength` builds the prior from it, and a club's own
expected goals only take over at half weight after eight matches.

**Form is one match in August.** FPL's `form` field is points per match over
the last thirty days, and it was used at a fixed 28% share of the projection.
In gameweek 2 that is a single afternoon: a wing-back who scored seventeen once
was projected above Haaland, and Haaland, who had a quiet opener, was marked
down by a point and a half a week for it. The share now grows with the number of
matches actually behind the average. The historical harness cannot catch this
class of bug — it blanks the current season, so `form` is always zero there —
which is what `--why` is for.

**`price_change_percent` is a string.** So are `projected_percent`, `form`,
`points_per_game` and every expected-goals field. `price_change_hourly_rate` and
`likelihood` are integers. Decoding one of them with the wrong type fails the
whole bootstrap and the app shows a network error for what is a parsing bug.
