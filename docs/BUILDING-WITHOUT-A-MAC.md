# Building this without a Mac

## The constraint, plainly

This is a native iPhone app. Compiling it requires the iOS SDK and Xcode, and
**Apple ships both only for macOS**. There is no Windows toolchain, no official
cross-compiler, and no legitimate workaround. Getting an app onto an iPhone also
requires code signing, which likewise only runs on macOS.

That is Apple's restriction, not a gap in this project. Every native iOS app in
the world is built on a Mac somewhere.

The good news: you need *access to* macOS, not *ownership of* a Mac. Below,
cheapest first.

## Option 1 — GitHub Actions (free, start here)

The single biggest risk in this repository is that **nothing has ever been
compiled**. You do not need a Mac to fix that; you need a macOS *runner*, and
GitHub gives those away.

`.github/workflows/ci.yml` is already written. It builds the engine, runs the
test suite, and does a simulator build of the app.

```powershell
cd "D:\Projects\Move it"
git init
git add .
git commit -m "Move It: on-device transit app"
gh repo create move-it --private --source=. --push
```

Push, open the Actions tab, and read the log. Every compile error in the project
appears there within a few minutes. Fix, push, repeat — no Mac involved.

Cost: free for public repos. Private repos get 2,000 minutes/month on the free
tier, but **macOS minutes bill at 10×**, so budget roughly 200 real minutes.
A run of this project is a few minutes, so that is plenty for iterating.

What this gets you: a compiling, tested, verified codebase.
What it does **not** get you: an app on your phone. For that, keep reading.

## Option 2 — Rent a Mac in the cloud (~$25–80/month)

A remote Mac you control by screen sharing. Install Xcode, open the project,
build, and deploy to a device or to TestFlight.

| Service | Rough cost | Notes |
|---|---|---|
| MacinCloud | ~$25–50/month | Cheapest managed option; pay-as-you-go tiers exist |
| Scaleway Mac mini | ~€0.10/hour, ~€80/month | Hourly, good if you work in bursts |
| MacStadium | ~$100+/month | Aimed at teams/CI, overkill for one app |
| AWS EC2 Mac | ~$0.65/hour | **24-hour minimum allocation per instance** — easy to run up a large bill by accident |

Prices are approximate and drift; check before committing.

## Option 3 — Buy a used Mac (~$350–500, one-off)

A second-hand M1 Mac mini runs Xcode perfectly well and will build this project
comfortably. If you intend to keep working on iOS, this is the option that stops
costing money.

## Option 4 — Borrow one

A friend's Mac for an afternoon is enough to get the project compiling and
sideloaded onto your phone.

---

## Getting it onto an actual iPhone

Once you have macOS access:

| What you want | What it costs | How long it lasts |
|---|---|---|
| App on **your own** iPhone | Free Apple ID | Re-sign every **7 days** |
| TestFlight, or your own phone without re-signing | Apple Developer Program, **$99/year** | 1 year, renewable |
| Public App Store release | Same $99/year + App Review | — |

For personal use, the free path is genuinely fine — you plug the phone in, hit
Run in Xcode, and re-run it once a week.

---

## The honest alternative: don't build an iOS app

If what you actually want is *a transit app you can use on your phone this
month*, and buying Mac access is not appealing, then a **web app** is the
pragmatic answer. It runs in Safari, installs to the home screen as a PWA, and
needs no Apple account, no signing and no Mac.

Be clear about the cost, though: the engine here is ~13,000 lines of Swift.
Porting it to TypeScript is a rewrite, not a translation — the parts that make it
work on-device (the memory-mapped columnar graph, the pointer-level RAPTOR loops)
are exactly the parts that map worst onto a browser. A web version would need a
different storage design (IndexedDB or WASM with a linear memory buffer) and
would be meaningfully slower.

It is a real option and there is already a tailnet publishing flow in this
project (`CREATE-WEB.md`) that would serve it to your phone privately. But it is
a second project, not a repackaging of this one.

## Recommendation

1. **Today, free:** push to GitHub and let CI compile it. That turns "written but
   unverified" into "known to build and pass its tests", which is the most
   valuable single step available and costs nothing.
2. **When you want it on your phone:** rent a cloud Mac for a month, or borrow
   one for an afternoon.
3. **Only if you decide against Mac access entirely:** treat the web app as a
   separate build, and plan for a rewrite of the engine rather than a port.
