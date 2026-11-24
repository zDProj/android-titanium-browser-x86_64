#!/bin/bash
set -eo pipefail

export SCRIPT_DIR=$(realpath $(dirname "${BASH_SOURCE[0]}"))
source "$SCRIPT_DIR/common.sh"

# Resume mode: skip fetch/patches on a cached tree that already has them
RESUME="${RESUME:-0}"
case "$RESUME" in
    0|1) ;;
    *) echo "::error::RESUME must be 0 or 1" >&2; exit 2 ;;
esac

set_keys
export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git # https://github.com/chromium/chromium.git
export DEBIAN_FRONTEND=noninteractive

echo "=== Target Chromium Version: $VERSION | CPUs: $(nproc) | $(date) ==="

# ─── APT dependencies ────────────────────────────────────────────────
sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin ccache
sudo dpkg --add-architecture i386; sudo apt-get update; sudo apt-get install -y libgcc-s1:i386

# ─── ccache setup ─────────────────────────────────────────────────────
# CCACHE_DIR can be set by the workflow (e.g. /data/ccache-browser for
# self-hosted, ~/.cache/ccache for GitHub-hosted via actions/cache).
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
mkdir -p "$CCACHE_DIR"

export CCACHE_BASEDIR="$SCRIPT_DIR"
export CCACHE_NOHASHDIR=1
export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,include_file_mtime,include_file_ctime,file_stat_matches,pch_defines}"

# Keep cache under GitHub's 10 GB actions/cache limit with room to spare
ccache --set-config=max_size="${CCACHE_MAXSIZE:-6G}"
ccache --set-config=compression="${CCACHE_COMPRESS:-true}"
ccache --set-config=compression_level="${CCACHE_COMPRESSLEVEL:-1}"

echo "=== ccache: version/config ==="
ccache --version | head -1
ccache -p | grep -E 'cache_dir|max_size|compression|sloppiness|base_dir|hash_dir' || true

echo "=== ccache: restored cache stats ==="
ccache -s

# Zero stats so this run's stats reflect only new work
ccache -z

# ─── depot_tools ──────────────────────────────────────────────────────
[ -d depot_tools ] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"

# ─── Chromium source ─────────────────────────────────────────────────
mkdir -p chromium/src/out/Default; cd chromium/src

marker=out/Default/.titanium-prepared
prepared_version=''
if [ -f "$marker" ]; then
    prepared_version=$(sed -n 's/^version=//p' "$marker" | head -1)
fi

write_marker() {
    # Record what this tree actually contains so a later session can tell a
    # resume (same version) from an upgrade (new version).
    printf 'version=%s\nvanadium=%s\nbuilt=%s\n' \
        "$VERSION" \
        "$(git -C "$SCRIPT_DIR/vanadium" rev-parse HEAD 2>/dev/null || echo unknown)" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
}

apply_patch_series() {
    # https://grapheneos.org/build#browser-and-webview
    rm -rf $SCRIPT_DIR/vanadium/patches/*trichrome-{apk-build-targets,browser-apk-targets}.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*{detailed,supported}-language*.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*javascript-optimizer-{site-setting,settings-UI}.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*component-updates.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*{pdf,PDF,for-content-public,toolbar-button,configs-from-config-app,config-app-parsing,new-tab-card,predictive-back}*.patch
    # rm -rf $SCRIPT_DIR/vanadium/patches/*crashpad*.patch
    replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "TITANIUM"
    replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Titanium"
    replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "titanium"

    git config --global user.email "titanium-build@localhost"
    git config --global user.name "Titanium Build"

    # Ensure no leftover rebase or am directory exists before starting
    git am --abort >/dev/null 2>&1 || true
    git rebase --abort >/dev/null 2>&1 || true
    rm -rf .git/rebase-apply .git/rebase-merge

    # Apply one patch at a time so a failure names the offending patch
    # instead of surfacing as a bare `git am` exit code.
    local p
    for p in $SCRIPT_DIR/vanadium/patches/*.patch; do
        if ! git am --whitespace=nowarn --keep-non-patch "$p"; then
            echo "::error::Failed to apply patch $(basename "$p") on $VERSION" >&2
            git am --abort >/dev/null 2>&1 || true
            rm -rf .git/rebase-apply .git/rebase-merge
            return 1
        fi
    done
}

resume_tree=0
upgrade_tree=0
if [ "$RESUME" = "1" ] && [ -d out/Default ]; then
    if [ "${UPGRADE_CACHE:-0}" = "1" ]; then
        # The workflow decided this cached tree no longer matches the recipe
        # (new Chromium version, patch.sh change, ...). Re-fetch sources but
        # keep third_party checkouts and out/Default objects.
        upgrade_tree=1
        echo "::notice::Upgrading cached tree (${prepared_version:-unknown} -> $VERSION) in place; build objects kept"
    elif [ -n "$prepared_version" ] && [ "$prepared_version" = "$VERSION" ]; then
        # An exact version match with a prepared marker resumes directly.
        resume_tree=1
        echo "::notice::Resuming cached checkout ($VERSION) — skipping fetch, patches, and runhooks"
    else
        upgrade_tree=1
        echo "::notice::Cached tree version (${prepared_version:-unknown}) does not match $VERSION — upgrading in place"
    fi
fi

if [ "$resume_tree" = "0" ]; then
    rm -f "$marker"
    # A previous session may have been interrupted inside `git am`; that
    # leaves a rebase state which blocks both checkout and `git am`.
    git am --abort >/dev/null 2>&1 || true
    git rebase --abort >/dev/null 2>&1 || true
    rm -rf .git/rebase-apply .git/rebase-merge
    git reset --hard >/dev/null 2>&1 || true

    if [ "$upgrade_tree" = "1" ]; then
        # Upgrade path: same steps as a cold checkout, but on top of the
        # cached tree so third_party checkouts and out/Default objects stay.
        # -f: a new Chromium version may add files that the old tree has as
        # untracked leftovers; they are recreated by gclient sync anyway.
        git checkout . >/dev/null 2>&1 || true
        git clean -fd >/dev/null 2>&1 || true
        git fetch --depth 1 $CHROMIUM_SOURCE "+refs/tags/$VERSION:refs/tags/$VERSION"
        git checkout -f -B main "$VERSION"
        cp $SCRIPT_DIR/.gclient ../.gclient
        apply_patch_series
    else
        git init
        git remote get-url origin >/dev/null 2>&1 || git remote add origin $CHROMIUM_SOURCE
        git am --abort >/dev/null 2>&1 || true
        git rebase --abort >/dev/null 2>&1 || true
        rm -rf .git/rebase-apply .git/rebase-merge
        git reset --hard >/dev/null 2>&1 || true

        head_version=$(git describe --tags --abbrev=0 2>/dev/null || true)
        if ! git rev-parse --verify main >/dev/null 2>&1 || [ "$head_version" != "$VERSION" ]; then
          if [ -n "$head_version" ] && [ "$head_version" != "$VERSION" ]; then
            echo "::warning::Existing checkout is $head_version, not $VERSION; replacing sources"
          fi
          # Fetch the tag into a local tag and create main at that commit.
          # Checking out the bare tag leaves a detached HEAD, which makes
          # every later git call fail on a cold tree. Explicit refspecs also
          # avoid git's DWIM creating refs/heads/*.
          git fetch --depth 1 $CHROMIUM_SOURCE "+refs/tags/$VERSION:refs/tags/$VERSION"
          git checkout -f -B main "$VERSION"
          cp $SCRIPT_DIR/.gclient ../.gclient
          apply_patch_series
        fi
    fi

    # Reset any dirty subprojects in third_party (e.g. from previous runs of patch.sh)
    # so gclient sync will not fail with "You have uncommitted changes".
    git submodule foreach --recursive 'git reset --hard HEAD && git clean -fd' 2>/dev/null || true
    find third_party -maxdepth 5 -name ".git" -type d -execdir git reset --hard HEAD \; -execdir git clean -fd \; 2>/dev/null || true

    gclient sync -D --no-history --nohooks
    gclient runhooks
    ./build/install-build-deps.sh --no-prompt
else
    # Bootstrap depot_tools on resumed tree
    if [ -x "$SCRIPT_DIR/depot_tools/ensure_bootstrap" ]; then
        ( cd "$SCRIPT_DIR/depot_tools" && ./ensure_bootstrap ) || true
    else
        "$SCRIPT_DIR/depot_tools/gclient" --version >/dev/null || true
    fi

    # Still need build deps on a fresh runner
    ./build/install-build-deps.sh --no-prompt
fi

if [ "$resume_tree" = "0" ]; then
    # Mark the tree as prepared for future resumes and record which version
    # the sources now contain, so a later session can tell resume from upgrade.
    write_marker
fi

# ─── Clang version for ccache ────────────────────────────────────────
CLANG_REV=$(cat third_party/llvm-build/Release+Asserts/cr_build_revision 2>/dev/null || true)
if [ -n "$CLANG_REV" ]; then
    export CCACHE_COMPILERCHECK="string:$CLANG_REV"
    echo "clang revision: $CLANG_REV"
else
    export CCACHE_COMPILERCHECK=content
    echo "::warning::cr_build_revision not found; using CCACHE_COMPILERCHECK=content"
fi

# ─── Patches ──────────────────────────────────────────────────────────
if [ "$resume_tree" = "0" ]; then
    git checkout .
    source $SCRIPT_DIR/patch.sh
fi

# ─── GN gen ──────────────────────────────────────────────────────────
wanted=$(mktemp)
cp $SCRIPT_DIR/args.gn "$wanted"
mkdir -p out/Default out/tmp out/release

if [ "$resume_tree" = "1" ] && [ -f out/Default/build.ninja ] \
   && cmp -s "$wanted" out/Default/args.gn; then
    rm -f "$wanted"
    echo "out/Default/args.gn unchanged and build.ninja exists; skipping gn gen"
else
    mv "$wanted" out/Default/args.gn
    gn gen out/Default
fi

# ─── Verify ccache is wired into toolchain ────────────────────────────
echo "=== ccache toolchain check ==="
TC_FILE=$(find out/Default -maxdepth 1 -name 'toolchain.ninja' -print -quit)
if [ -n "$TC_FILE" ]; then
    if ! grep -q 'ccache' "$TC_FILE"; then
        echo "::warning::ccache not found in toolchain.ninja — build will be uncached"
        grep -m3 -E 'command = .*clang' "$TC_FILE" || true
    else
        grep -m1 -E 'command = .*ccache' "$TC_FILE" | cut -c1-220
    fi
fi

# ─── Preflight stop (no compile) ─────────────────────────────────────
# Exercises the expensive-to-debug part of an upgrade — tag fetch, patch
# series, gclient sync, gn gen — in ~20 minutes instead of discovering a
# break deep inside a multi-hour compile session.
if [ "${PREFLIGHT:-0}" = "1" ]; then
    echo "::notice::Preflight OK: $VERSION sources, patches and gn gen succeeded; skipping compile"
    exit 0
fi

# ─── System info before compile ──────────────────────────────────────
echo "=== System before compilation ==="
df -h / | tail -1
free -g 2>/dev/null | head -2 || true

echo "=== STAGE: compile start $(date) ==="
stdbuf -oL -eL autoninja -C out/Default chrome_public_apk
echo "=== STAGE: compile done $(date) ==="

ccache -s

# ─── Move and sign APK ───────────────────────────────────────────────
mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-x86_64.apk

export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public
sign_apk out/tmp/$VERSION-x86_64.apk out/release/$VERSION-x86_64.apk

echo "=== Build finished successfully! $(date) ==="
ccache -s

rm -rf $SCRIPT_DIR/keys
