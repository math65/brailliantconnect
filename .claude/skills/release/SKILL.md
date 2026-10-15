---
name: release
description: Cut and publish a new version — version numbers, release notes, notarized bundle, GitHub release. Use whenever a version is being published; the version lives in three places and the notes in two languages, and every step here exists because skipping it ships something broken.
---

# Publish a version

Nothing here is optional, and none of it can be checked afterwards from the
outside: an unnotarized bundle looks fine on this machine and is refused on
every other one, and a version number that drifts is only noticed in a bug
report six weeks later.

Run every step in order. Report what each one produced.

## 1. Decide the number, and say why

Semantic versioning, read from the user's point of view rather than the code's:

- **patch** (1.0.**1**) — a fix, nothing new to learn;
- **minor** (1.**1**.0) — something the user can now do that they could not;
- **major** (**2**.0.0) — something they knew how to do no longer works that way.

## 2. Set it in all three places

- `MARKETING_VERSION` — the version users see. It appears **twice** in
  `project.pbxproj`, in the **project-level** Debug and Release
  configurations; neither target sets its own, so the app and the extension
  both inherit it. Both lines must move, or a Release build and a Debug build
  of the same commit report different versions.
- `CURRENT_PROJECT_VERSION` — the build number (`CFBundleVersion`), also
  twice, also project-level. It goes up with **every** bundle that leaves this
  machine, betas included, and never repeats (1.1.1 is build 6, the beta
  before it build 5). Nothing checks it — a forgotten bump ships a bundle
  that macOS cannot tell from the previous one.
- `Sources/BrailliantKit/Version.swift` — what `brailliant --version` and
  `doctor` report. It is not read from the bundle: the CLI runs from
  `.build/release/` where there is no bundle at all.

```bash
cd "$(git rev-parse --show-toplevel)"
NEW=1.2.3   # <- the number decided above
BUILD=7     # <- the previous CURRENT_PROJECT_VERSION plus one
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $NEW;/g" \
  App/BrailliantConnect.xcodeproj/project.pbxproj
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD;/g" \
  App/BrailliantConnect.xcodeproj/project.pbxproj
sed -i '' "s/public static let current = \".*\"/public static let current = \"$NEW\"/" \
  Sources/BrailliantKit/Version.swift
grep -c "MARKETING_VERSION = $NEW;" App/BrailliantConnect.xcodeproj/project.pbxproj  # expect 2
grep -c "CURRENT_PROJECT_VERSION = $BUILD;" App/BrailliantConnect.xcodeproj/project.pbxproj  # expect 2
```

## 3. Let the test prove they agree

```bash
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
```

`VersionTests` parses the Xcode project and compares `MARKETING_VERSION` with
`Version.swift`. It is the only thing standing between two numbers that
quietly disagree — read its failure, never work around it. It does not look at
the build number.

## 4. Write the notes, in both languages

`RELEASE_NOTES.md` and `RELEASE_NOTES.fr.md`, newest section on top, dated
`## vX.Y.Z — DD/MM/YYYY`. They are not a changelog: say what changed **for
someone using the app**, and why it matters. A user who reads "refactored the
diagnostics collector" learns nothing.

The two files are written, not translated: French and English each read as if
they were the original. Neither is allowed to carry a fact the other does not.

## 5. Build the distributable bundle

```bash
./tools/make-dist.sh --notarize
```

The script refuses to run without `--notarize`: the ad-hoc mode it once had
could not produce a bundle that works (see the header of `make-dist.sh`).

Before building, it checks what would otherwise fail only after a ten-minute
build, or only on a user's Mac:

- the Developer ID certificate in the keychain is one of those inside the
  provisioning profile — compared by SHA-1. If not, the agent would be killed
  at launch; regenerate the profile (below);
- the certificate's own expiry date, printed, with a warning under 60 days;
- `App/BrailliantConnect/AppBackendSecret.plist` exists, and after the build
  that the bundle carries it: without it the release has no *Report a
  Problem* and never sees an announcement.

Then it runs the test suite and refuses to package if anything fails. It also
refuses a bundle carrying `get-task-allow`. Xcode adds that entitlement
whenever it signs for **development** (an *Apple Development* identity) — in
Release as in Debug — and never with the Developer ID identity the archive is
signed with. If the script stops there, the archive was signed for development:
look at the signing settings Xcode used (`dist/xcodebuild-archive.log`), not at
`/Applications`, which the script never reads.

Every step that can fail long leaves a log in `dist/` (`swift-test.log`,
`swift-build.log`, `xcodebuild-archive.log`, `xcodebuild-export.log`,
`notarytool.log`) and prints its tail on failure. A refused notarisation
prints Apple's own log for the submission. A Gatekeeper rejection after
stapling stops the script.

Notarizing takes a few minutes. The script staples the ticket and re-zips, so
the archive works offline.

With `--notarize` the agent is also signed with
`App/BrailliantConnect/BrailliantConnect-distribution.entitlements` and
carries `App/BrailliantConnect/BrailliantConnect.provisionprofile` as
`Contents/embedded.provisionprofile`: that is what lets macOS 13 publish the
location at all (see **macOS 13** in `CLAUDE.md`). The script refuses to
package without either. The profile itself expires in 2044, which means
nothing: it is only valid together with the certificates it lists. The one it
was made with (9 Sep 2026) expires on 1 February 2027; the keychain has held a
renewed certificate since 2 October 2026 (expires 17 September 2031), which the
committed profile does **not** list. After any certificate renewal, regenerate
the profile on the portal (Profiles → Developer ID → App ID
`com.mathieumartin.BrailliantConnect`, with the current certificate) and
replace the file — the script refuses to package until they match.

## 6. If the `/extension` loop ran recently

Testing the extension puts a **Debug** build in `/Applications`. It is not the
one to ship. The release build in `dist/` is the artifact; install it over the
Debug one before claiming anything about how the app behaves.

## 7. Commit, tag, publish

```bash
git add -A && git commit    # subject in English, body saying why
git tag -a "v$NEW" -m "BrailliantConnect $NEW"
git push && git push --tags
# The notes file holds every version ever released. Cut the new section out,
# or the release page repeats the whole history.
python3 - "$NEW" <<'EOF' > /tmp/notes.md
import io, sys
s = io.open("RELEASE_NOTES.md", encoding="utf-8").read()
start = s.index("## v" + sys.argv[1])
rest = s.find("\n## v", start + 1)
print(s[start:rest if rest > 0 else len(s)].rstrip())
EOF
gh release create "v$NEW" dist/BrailliantConnect.zip \
  --title "BrailliantConnect $NEW" --notes-file /tmp/notes.md
```

Link the **file**, not the release page, wherever the download is announced.
The page hides its archive under a collapsed "Assets" section, which is one
more thing to hunt for with a screen reader:
`…/releases/download/vX.Y.Z/BrailliantConnect.zip`.

Publishing is public and hard to take back. Show the user the notes and the
version number, and get an explicit yes before this step — never as a
side effect of "make a release".

## 8. Tell the people who already installed it

There is no update mechanism: someone running the previous version learns
nothing on their own.

The announcement channel in the admin backend reaches them — but **only from
1.1.0 onwards**, the version that added the client that asks for announcements.
An older install has nothing polling the backend and will never see one, so
check what the oldest version in the wild is before assuming an announcement
covers anybody. It never reaches people who have not updated yet, which is the
audience an update announcement is aimed at; it works for everything after
their next update.

Ask the user whether to post one; it is their voice, not yours.

The AppleVis thread is the other half of that audience, and the same rule
applies: draft, show, let them post.
