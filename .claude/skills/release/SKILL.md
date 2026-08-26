---
name: release
description: Cut and publish a new version — version numbers, release notes, notarized bundle, GitHub release. Use whenever a version is being published; the version number lives in two places and the notes in two languages, and every step here exists because skipping it ships something broken.
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

## 2. Set it in both places

`MARKETING_VERSION` appears **twice** in `project.pbxproj` — once per target —
and both must move: the extension carries its own version, and a mismatch is
what makes an install look updated while its Finder side is not.

```bash
cd "$(git rev-parse --show-toplevel)"
NEW=1.2.3   # <- the number decided above
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $NEW;/g" \
  App/BrailliantConnect.xcodeproj/project.pbxproj
sed -i '' "s/public static let current = \".*\"/public static let current = \"$NEW\"/" \
  Sources/BrailliantKit/Version.swift
grep -c "MARKETING_VERSION = $NEW;" App/BrailliantConnect.xcodeproj/project.pbxproj  # expect 2
```

`Version.swift` is what `brailliant --version` and `doctor` report, and it is
not read from the bundle — the CLI runs from `.build/release/` where there is
no bundle at all.

## 3. Let the test prove they agree

```bash
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
```

`VersionTests` parses the Xcode project and compares. It is the only thing
standing between two numbers that quietly disagree — read its failure, never
work around it.

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

**Never without `--notarize`.** Without it the bundle is signed ad-hoc:
Gatekeeper accepts it on this machine and refuses it on every other, which is
precisely the failure nobody can reproduce locally.

The script runs the test suite first and refuses to package if anything fails.
It also refuses a bundle carrying `get-task-allow` — a debug build, which any
process could attach to. If it stops there, `/Applications` or the archive is
holding a Debug build: see step 6.

Notarizing takes a few minutes. The script staples the ticket and re-zips, so
the archive works offline.

## 6. If the `/extension` loop ran recently

Testing the extension puts a **Debug** build in `/Applications`. It is not the
one to ship, and it is the usual cause of a `get-task-allow` refusal. The
release build in `dist/` is the artifact; install it over the Debug one before
claiming anything about how the app behaves.

## 7. Commit, tag, publish

```bash
git add -A && git commit    # subject in English, body saying why
git tag -a "v$NEW" -m "BrailliantConnect $NEW"
git push && git push --tags
gh release create "v$NEW" dist/BrailliantConnect.zip \
  --title "BrailliantConnect $NEW" --notes-file RELEASE_NOTES.md
```

Publishing is public and hard to take back. Show the user the notes and the
version number, and get an explicit yes before this step — never as a
side effect of "make a release".

## 8. Tell the people who already installed it

There is no update mechanism: someone running the previous version learns
nothing on their own. The announcement channel in the admin backend is the only
way to reach them — an announcement with a link button pointing at the release
page. Ask the user whether to post one; it is their voice, not yours.

The AppleVis thread is the other half of that audience, and the same rule
applies: draft, show, let them post.
