# Shipping — from Windows to TestFlight to the App Store

This repository is authored on Windows. Apple ships Xcode only for macOS, so
building it requires a Mac somewhere — but *somewhere* can be a GitHub runner,
and this document is the setup that makes that true.

Nothing here needs you to own, rent, or borrow a Mac.

---

## How it works

`.github/workflows/release.yml` runs on a GitHub macOS runner. It generates the
Xcode project, archives the app, signs it, and uploads it to TestFlight.

The part that usually forces people onto a Mac is code signing: normally you
create a distribution certificate in Xcode, export a `.p12`, and feed it to CI.
That first step needs a Mac.

We skip it. `xcodebuild -allowProvisioningUpdates`, given an **App Store Connect
API key**, will create the certificate and the provisioning profile *on the
runner itself*. The API key is created in a browser, so Windows is not a
constraint anywhere in the chain.

---

## One-time setup

### 1. Create an App Store Connect API key

1. <https://appstoreconnect.apple.com> → **Users and Access** → **Integrations**
2. Left sidebar: **App Store Connect API** → **Team Keys**
3. **+**, name it `GitHub CI`, access **Admin**, **Generate**
   > **Admin, not App Manager.** App Manager can upload a build but cannot
   > create a distribution certificate, so `-exportArchive` fails with
   > "Cloud signing permission error". A key's role cannot be changed after
   > it is generated — getting this wrong costs you a new key.
4. **Download the `.p8` — Apple allows this exactly once.** Keep it safe.
5. Note the **Key ID** (10 characters) and the **Issuer ID** (a UUID at the top).

### 2. Find your Team ID

<https://developer.apple.com/account> → **Membership details** → **Team ID**.
Ten characters, something like `A1B2C3D4E5`.

### 3. Register the App ID

1. <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles**
2. **Identifiers** → **+** → **App IDs** → **App** → Continue
3. Description `Yalla Sa`, **Explicit**, Bundle ID `com.yallasa.app`
4. Leave every capability unchecked — the app uses no push, no background modes,
   no iCloud, no App Groups. Anything ticked here becomes an entitlement the
   binary must justify at review.
5. **Continue** → **Register**

### 4. Create the app record

1. <https://appstoreconnect.apple.com> → **Apps** → **+** → **New App**
2. Platform **iOS**, Name **יאללה סע**, Primary Language **Hebrew**
3. Bundle ID `com.yallasa.app`, SKU `yallasa-001`
4. **Create**

> If the name is taken, App Store Connect says so immediately. Pick another and
> keep the bundle ID as it is — they are independent.

### 5. Add four repository secrets

GitHub → repository → **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**, four times:

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | the 10-character Key ID from step 1 |
| `ASC_ISSUER_ID` | the issuer UUID from step 1 |
| `ASC_KEY_P8` | the entire contents of the `.p8` file, including the `-----BEGIN`/`-----END` lines |
| `ASC_TEAM_ID` | the Team ID from step 2 |

The workflow checks all four before doing anything else, so a missing one fails
in seconds with a readable message rather than twenty minutes into an archive.

---

## Producing a build

GitHub → **Actions** → **Release (TestFlight)** → **Run workflow**.

It takes roughly 15–25 minutes. The build number is `github.run_number`, which is
monotonic and never reused — exactly the contract TestFlight wants. You do not
have to bump anything by hand.

Then:

1. App Store Connect → **TestFlight** → the build appears after 5–15 minutes of
   processing
2. **Internal Testing** → add yourself → you get an email
3. Install **TestFlight** from the App Store on the iPhone → the app is there

Internal testers need no Beta App Review, so this path is minutes, not days.

---

## What App Review will want

Beyond the binary:

- **Screenshots** for 6.7" and 6.5" displays. Take them on the phone once the
  app runs.
- **A privacy policy URL.** Required for every app. It can be a single static
  page; the honest content is short, because nothing is collected.
- **Privacy nutrition labels.** For this app the answer is **Data Not
  Collected** — there is no server to collect anything to. `PrivacyInfo.xcprivacy`
  already declares the two required-reason APIs the code actually calls
  (file timestamps, `UserDefaults`).
- **Export compliance.** Already answered: `ITSAppUsesNonExemptEncryption` is
  `false` in `Info.plist`, so the upload does not stop to ask.
- **A demo account.** Not applicable — there are no accounts.

### The one review risk worth planning for

On first launch the app asks the reviewer to download a transit feed before it
does anything. A reviewer on a slow or restricted network who is handed a 133 MB
Israeli national archive may simply fail the app as broken.

Make the default offered feed a small one, and make the first-run screen say
plainly what is being downloaded and how big it is.

---

## Cost

The repository is public, so GitHub Actions minutes are free — including macOS
runners, which bill at 10× on private repositories. Iterating on the build costs
nothing but wall-clock time.

The Apple Developer Program is $99/year, which this account already has.
