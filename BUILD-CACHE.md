# Cached builds

`.github/workflows/build-cached.yml` restores a prepared Chromium tree from the
`build-cache` (prerelease) release, so a Chromium build can span several
GitHub-hosted sessions instead of starting from zero every time.

## Generations

The tree is uploaded as `gNNN-part-*` assets plus:

| asset | contents |
|---|---|
| `manifest.txt` | describes the generation a new run should restore |
| `gNNN.meta` | same fields for one generation; uploaded last, so its presence means "complete" |

Both carry `recipe=` (sha256 of `args.gn`, `patch.sh`, `.gclient` and the
`vanadium` SHA), `version=`, `parts=`, `remaining=` and `apk=` (release file name
when that session published an APK).

## Which tree is restored

1. same recipe → plain resume (no fetch, no patches, no runhooks)
2. same Chromium version, different recipe (e.g. `patch.sh` changed) → restore
   and re-apply the patch series on the same sources
3. anything else → **in-place upgrade**: `git fetch` the new tag,
   `git checkout -f -B main <tag>`, re-apply patches, `gclient sync` (deltas
   only). `third_party` checkouts and `out/Default` object files are kept, so
   only the delta compiles.

`build.sh` records `version=`, `vanadium=` and `built=` in
`chromium/src/out/Default/.titanium-prepared`; `UPGRADE_CACHE=1` forces the
upgrade path, and a checkout that is not at `$VERSION` is always replaced so a
run can never silently build the previous version.

## Retention

After a save, generations that are neither the new one nor a keeper are
deleted. The keeper is the last generation that published an APK (or, if none
is recorded, the newest other generation). A session that publishes an APK
prunes every older generation, so steady state is one generation and an
upgrade in progress costs at most two.

## Actions

| action | use |
|---|---|
| `continue` | normal build, resuming or upgrading from cache, auto-chains on budget |
| `preflight` | fetch tag, apply patches, `gclient sync`, `gn gen`, save cache — no compile. Run this after merging an upstream Chromium bump: breakage shows up in ~20–40 min with a named patch instead of hours into a session |
| `reset` | cold build, restore skipped |
| `seed` | same as `continue` on the self-hosted runner |
| `probe` | inspect the cached tree only |

## After an upstream bump

1. dispatch `action=preflight` — it fails loudly on the first patch that no
   longer applies (`::error::Failed to apply patch 0042-....patch on <version>`)
2. dispatch `action=continue`; it restores the preflight tree and compiles

If the upgrade cannot be made to work, revert `vanadium`, `patch.sh`, `args.gn`
and `.gclient` to the last good values; the previous version's tree is still in
the cache and matches its old recipe, so the rollback build resumes instead of
starting cold.
