# Releasing

Two independent things get released from this repository. **Do not mix them up.**

| What | Tag | Marketplace | `make_latest` |
| --- | --- | --- | --- |
| The action itself | `v1.2.3` (+ moving `v1`) | yes | true |
| refinery binaries | `refinery-v0.9.2` | no | **false** |

A bare `v0.9.2` tag must never exist here: it would be a valid
`uses: danielsan/setup-refinery@v0.9.2` and read as an action version. `build-upstream.yml` has a
guard job that enforces both tag patterns.

## Releasing refinery binaries

Usually automatic: `watch-upstream.yml` polls crates.io daily and builds any new stable version.

To build one by hand:

```bash
gh workflow run build-upstream.yml -f version=0.9.2
# dry run: build and verify everything, publish nothing
gh workflow run build-upstream.yml -f version=0.9.2 -f dry_run=true
# rebuild assets that already exist
gh workflow run build-upstream.yml -f version=0.9.2 -f force=true
```

The pipeline creates the release as a **draft**, uploads assets, aggregates `SHA256SUMS`, refuses to
continue if any of the five targets is missing, smoke-tests the real action against the draft on all
five runner platforms, and only then publishes. Nothing is consumable until that passes.

## Releasing the action

1. Make sure `ci.yml` is green on `main`.
2. Update the README if inputs, outputs or platforms changed. Remember that inputs are a permanent
   API: adding an optional defaulted input is fine, adding a required one or removing any is a
   breaking change.
3. Write the release notes under `.github/release-notes/v1.2.3.md` and create the release with
   them. `--generate-notes` alone produces a commit list, which is not what a Marketplace visitor
   should be reading — the release body is sales copy as much as a changelog:
   ```bash
   gh release create v1.2.3 --title "setup-refinery v1.2.3" \
     --notes-file .github/release-notes/v1.2.3.md
   ```
   Keep any measured numbers in the notes honest: re-measure them from the verification run for
   that release rather than copying the previous version's table.
4. `major-tag.yml` moves `v1` automatically on publish.
5. **Manual step:** tick *"Publish this Action to the GitHub Marketplace"* in the release UI. This
   cannot be done through the API.

### First release only

- [ ] Repository is **public** (Marketplace requires it).
- [ ] 2FA is enabled on the publishing account.
- [ ] The Marketplace listing name `Setup refinery CLI` is globally unique — this cannot be checked
      via the API, so confirm it in the publish dialog. It must also not collide with a GitHub
      user/org name or a Marketplace category.
- [ ] Primary category: **Utilities**. Secondary: **Continuous integration**.
- [ ] Repository topics set: `github-action`, `refinery`, `sql-migrations`,
      `database-migrations`, `rust`, `setup`.
- [ ] Tag protection ruleset on `v*` and `refinery-v*`: block deletion and force-push. Third parties
      download these assets, so a moved tag is a supply-chain event.

## Bumping the pinned Rust toolchain

The toolchain version is pinned in `build-upstream.yml` (`dtolnay/rust-toolchain` `toolchain:`).
Bumping it changes every produced binary, so do it in its own commit and run a `dry_run=true` build
across all five targets first.
