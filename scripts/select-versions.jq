# Given the GitHub /releases JSON on stdin and $ENV.TARGET set, emit the version
# of every published release that has an installable asset for that target.
#
# Kept in its own file so scripts/setup.sh and test/unit.sh use the identical
# text and cannot drift. Tested by test/unit.sh against recorded fixtures --
# which is the only way to cover cases like "release exists but this target's
# asset is missing" that are impossible to produce live.
.[]

# Drafts and prereleases are never installable by consumers.
| select(.draft == false and .prerelease == false)

# Only binary-payload releases. This is also why /releases/latest is never used:
# it returns the newest release by date, which is normally an ACTION release
# (v1.x) carrying no binaries at all.
| select(.tag_name | test("^refinery-v[0-9]+\\.[0-9]+\\.[0-9]+$"))

# `.v` must be bound with `as` before the any(...) below: inside it the context
# is each asset NAME, so a bare `.v` fails with "Cannot index string with v".
| (.tag_name | ltrimstr("refinery-v")) as $v
| [.assets[].name] as $names

# Exact names, not a prefix match, so a stray `.sha256` sidecar can never be
# mistaken for a present archive. The filter is per-TARGET, which is what makes
# `latest` degrade gracefully: if one platform's upload failed, consumers on
# that platform resolve to the previous good version instead of hard-failing.
| select(
    $names | any(
      . == "refinery-\($v)-\($ENV.TARGET).tar.gz"
      or . == "refinery-\($v)-\($ENV.TARGET).zip"
    )
  )
| $v
