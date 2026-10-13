#!/bin/bash
# Resumable multi-stage Titanium/Chromium build for GitHub's free runners (arm64-v8a APK only).
#
#   bash ci/staged.sh build    restore or prepare the tree, build until the time budget runs out
#   bash ci/staged.sh save     checkpoint the tree + out/ as release assets (the "build-state" release)
#   bash ci/staged.sh finish   sign the APK and publish it
#
# NOTE: no global `set -e`. build.sh / patch.sh from this repo rely on non-fatal failures,
# so critical sections below use subshells with `set -eo pipefail` or explicit checks.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/common.sh"          # replace(), set_keys(), sign_apk()
export SCRIPT_DIR="$ROOT"         # common.sh derives it from $0; we live in ci/

META="$ROOT/.stage"               # small per-run notes, never part of a checkpoint
TAG=${STATE_TAG:-build-state}
REPO=${GITHUB_REPOSITORY:-}
GH=${GH_BIN:-gh}
JOB_LIMIT=${JOB_LIMIT:-21000}     # 5h50m of the 6h hard limit
RESERVE=${RESERVE:-4200}          # seconds kept back for checkpointing after the build pauses
CHUNK=${CHUNK:-1000M}             # release assets must stay below 2 GiB
MAX_STAGES=${MAX_STAGES:-14}
OFFICIAL=${OFFICIAL:-false}
FRESH=${FRESH:-false}
REAPPLY=${REAPPLY:-false}
PUBLISH=${PUBLISH:-true}
RUN_START=${RUN_START:-$(date +%s)}
CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git
VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' "$ROOT/vanadium/args.gn" 2>/dev/null || true)
export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "::error::$*"; exit 1; }
out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

retry() {
  local n=$1 i; shift
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    echo "retry $i/$n failed: $*" >&2
    sleep $((i * 15))
  done
  return 1
}

# ---------------------------------------------------------------- checkpoint storage (release assets)
# Layout:  gen-<N>.part-000 ... gen-<N>.part-NNN  +  gen-<N>.manifest (uploaded LAST = "complete" marker)

asset_names() { $GH api "repos/$REPO/releases/tags/$TAG" --jq '.assets[].name' 2>/dev/null; }

ensure_release() {
  $GH api "repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1 && return 0
  $GH release create "$TAG" -R "$REPO" --prerelease --title "build state (temporary)" \
    --notes "Temporary checkpoints of an in-progress build. Safe to delete." >/dev/null
}

latest_gen() { asset_names | sed -n 's/^gen-\([0-9]\+\)\.manifest$/\1/p' | sort -n | tail -n1; }

prune_state() {   # prune_state <generation to keep | none>
  local keep=$1 n
  for n in $(asset_names); do
    case "$n" in
      gen-"$keep".*) ;;
      *) $GH release delete-asset "$TAG" "$n" -y -R "$REPO" ;;
    esac
  done
}

upload_part() {   # called by `split --filter`, $FILE = chunk name, chunk bytes on stdin
  local f="$TMPD/$FILE"
  cat > "$f"
  echo "$(sha256sum "$f" | cut -d' ' -f1)  $FILE" >> "$TMPD/manifest"
  retry 5 $GH release upload "$TAG" "$f" --clobber -R "$REPO" >/dev/null || exit 1
  rm -f "$f"
}

save_state() (
  # NOTE: callers may use this in `||` / `&&` lists, which disables `set -e` inside, so every
  # critical command below checks its own status explicitly.
  set -o pipefail
  local gen=$1
  export TMPD="$META/up" GH TAG REPO STAGED_SH="$ROOT/ci/staged.sh"
  rm -rf "$TMPD"; mkdir -p "$TMPD"; : > "$TMPD/manifest"
  ensure_release || exit 1
  prune_state "$(latest_gen || true)" || exit 1  # drop leftovers of an interrupted earlier save
  log "saving checkpoint gen-$gen"
  { tar --format=posix --pax-option=delete=atime,delete=ctime -C "$ROOT" -cf - chromium depot_tools \
      || [ $? -eq 1 ]; } \
    | zstd -T0 -3 -q \
    | split -b "$CHUNK" -d -a 3 --filter='bash "$STAGED_SH" upload-part' - "gen-$gen.part-" || exit 1
  [ -s "$TMPD/manifest" ] || { echo "empty checkpoint, refusing to publish it" >&2; exit 1; }
  cp "$TMPD/manifest" "$TMPD/gen-$gen.manifest" || exit 1
  retry 5 $GH release upload "$TAG" "$TMPD/gen-$gen.manifest" --clobber -R "$REPO" >/dev/null || exit 1
  prune_state "$gen" || exit 1                    # only now remove the previous generation
  rm -rf "$TMPD"
  log "checkpoint gen-$gen saved"
)

restore_state() (
  set -o pipefail
  local gen=$1 d="$META/dl"
  mkdir -p "$d"
  retry 5 $GH release download "$TAG" -p "gen-$gen.manifest" -D "$d" --clobber -R "$REPO" >/dev/null || exit 1
  [ -s "$d/gen-$gen.manifest" ] || { echo "manifest for gen-$gen is empty" >&2; exit 1; }
  log "restoring checkpoint gen-$gen ($(wc -l < "$d/gen-$gen.manifest") parts)"
  (
    while read -r sum name; do
      f="$d/$name"
      for i in 1 2 3 4 5; do
        if $GH release download "$TAG" -p "$name" -O "$f" --clobber -R "$REPO" >/dev/null 2>&1 \
           && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ]; then break; fi
        echo "part $name attempt $i failed" >&2; rm -f "$f"; sleep $((i * ${PART_RETRY_SLEEP:-10}))
        [ "$i" -eq 5 ] && exit 1
      done
      cat "$f"; rm -f "$f"
    done < "$d/gen-$gen.manifest"
  ) | zstd -d -T0 -q | tar -x -C "$ROOT" --no-same-owner || exit 1
  [ -f "$ROOT/chromium/.titanium_prep_done" ] || { echo "restored tree has no prep marker" >&2; exit 1; }
  rm -rf "$d"
)

# ---------------------------------------------------------------- tree preparation (mirrors build.sh)

setup_system() {
  sudo apt-get update -y
  sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin zstd
  sudo dpkg --add-architecture i386; sudo apt-get update -y; sudo apt-get install -y libgcc-s1:i386
  git config --global user.name 'github-actions[bot]'
  git config --global user.email 'github-actions[bot]@users.noreply.github.com'
}

make_args() {   # run inside chromium/src
  cp "$ROOT/args.gn" out/Default/args.gn
  sed -i 's/target_cpu = "arm"/target_cpu = "arm64"/' out/Default/args.gn
  if [ "$OFFICIAL" != "true" ]; then
    # Much cheaper than the official ThinLTO configuration; needed to fit a 4-core runner.
    sed -i -e 's/^is_official_build = true/is_official_build = false/' \
           -e 's/^symbol_level = .*/symbol_level = 0/' \
           -e '/^generate_linker_map/d' out/Default/args.gn
    printf 'blink_symbol_level = 0\nv8_symbol_level = 0\ntreat_warnings_as_errors = false\n' >> out/Default/args.gn
  fi
}

prepare() {
  [ -n "$VERSION" ] || die "could not read the Chromium version from vanadium/args.gn (submodule missing?)"
  cd "$ROOT" || return 1
  rm -rf chromium depot_tools
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git || return 1
  export PATH="$ROOT/depot_tools:$PATH"
  mkdir -p chromium/src/out/Default; cd chromium/src || return 1
  git init -q; git remote add origin "$CHROMIUM_SOURCE"
  git fetch --depth 1 "$CHROMIUM_SOURCE" "+refs/tags/$VERSION:chromium_$VERSION" || return 1
  git checkout -q "$VERSION" || return 1
  cp "$SCRIPT_DIR/.gclient" ../.gclient

  # https://grapheneos.org/build#browser-and-webview  (same list as build.sh)
  rm -rf "$SCRIPT_DIR"/vanadium/patches/*trichrome-{apk-build-targets,browser-apk-targets}.patch
  rm -rf "$SCRIPT_DIR"/vanadium/patches/*{detailed,supported}-language*.patch
  rm -rf "$SCRIPT_DIR"/vanadium/patches/*javascript-optimizer-{site-setting,settings-UI}.patch
  rm -rf "$SCRIPT_DIR"/vanadium/patches/*component-updates.patch
  rm -rf "$SCRIPT_DIR"/vanadium/patches/*{pdf,PDF,for-content-public,toolbar-button,configs-from-config-app,config-app-parsing,new-tab-card,predictive-back}*.patch
  replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "TITANIUM"
  replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Titanium"
  replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "titanium"
  git am --whitespace=nowarn --keep-non-patch "$SCRIPT_DIR"/vanadium/patches/*.patch || return 1

  gclient sync -D --no-history --nohooks || return 1
  log "after gclient sync: $(df -h "$ROOT" | tail -n1)"
  gclient runhooks || return 1
  ./build/install-build-deps.sh --no-prompt || return 1

  source "$SCRIPT_DIR/patch.sh"
  make_args
  gn gen out/Default || return 1
  log "preparation done: $(df -h "$ROOT" | tail -n1)"
  touch "$ROOT/chromium/.titanium_prep_done"
}

post_restore() {
  export DEPOT_TOOLS_UPDATE=0
  export PATH="$ROOT/depot_tools:$PATH"
  cd "$ROOT/chromium/src" || return 1
  ./build/install-build-deps.sh --no-prompt || log "install-build-deps failed (continuing)"
  if [ "$REAPPLY" = "true" ]; then
    log "re-applying patch.sh on the restored tree"
    git checkout -- .                      # revert only what patch.sh changed (tracked files)
    source "$SCRIPT_DIR/patch.sh"
    make_args
    gn gen out/Default || return 1
  fi
}

# ---------------------------------------------------------------- build with a hard time budget

run_build() {   # run_build <deadline epoch>; sets BUILD_INTERRUPTED=1 when we stopped it ourselves
  # Foreground GNU `timeout`: sends SIGINT to the whole process group (siso/ninja shut down cleanly and
  # flush their state), then SIGKILL after 10 min. A background job would start with SIGINT ignored.
  local deadline=$1 secs rc=0
  BUILD_INTERRUPTED=0
  cd "$ROOT/chromium/src" || return 1
  secs=$((deadline - $(date +%s)))
  if [ "$secs" -lt "${MIN_BUILD_SECS:-300}" ]; then
    echo "::warning::less than 5 minutes of build time left, skipping straight to the checkpoint"
    BUILD_INTERRUPTED=1; return 1
  fi
  timeout -s INT -k 600 "$secs" autoninja -C out/Default chrome_public_apk || rc=$?
  case "$rc" in 124|137) BUILD_INTERRUPTED=1 ;; esac
  return "$rc"
}

# ---------------------------------------------------------------- subcommands

cmd_build() {
  mkdir -p "$META"
  df -h "$ROOT" | tail -n1
  setup_system || die "apt setup failed"

  [ "$FRESH" = "true" ] && { log "fresh start requested: dropping checkpoints"; ensure_release; prune_state none; }
  local gen; gen=$(latest_gen || true)

  if [ -z "$gen" ]; then
    next=1
    log "no checkpoint found: preparing a new tree (stage 1)"
    prepare || { out result failed_prep; die "tree preparation failed (nothing saved)"; }
  else
    next=$((gen + 1))
    [ "$gen" -ge "$MAX_STAGES" ] && die "reached max_stages=$MAX_STAGES; raise it or use fresh=true"
    log "resuming from checkpoint gen-$gen (stage $next)"
    restore_state "$gen" || { out result failed_restore; die "could not restore checkpoint gen-$gen"; }
    post_restore || { out result failed_prep; die "post-restore setup failed"; }
  fi
  echo "$next" > "$META/next_gen"
  out next_gen "$next"
  df -h "$ROOT" | tail -n1

  local deadline=$((RUN_START + JOB_LIMIT - RESERVE))
  log "building until $(date -u -d "@$deadline" +%H:%M:%S) UTC ($(( (deadline - $(date +%s)) / 60 )) min available)"
  export PATH="$ROOT/depot_tools:$PATH"
  local rc=0
  run_build "$deadline" || rc=$?

  if [ "$BUILD_INTERRUPTED" = "1" ]; then out result paused;  log "paused: will checkpoint and continue in the next stage"
  elif [ "$rc" -eq 0 ];             then out result complete; log "build finished"
  else                                   out result failed;   log "build failed (rc=$rc); progress will still be checkpointed"
  fi
  return 0
}

cmd_save() {
  if [ -z "$IN_TIMEOUT" ]; then            # never run past the 6h hard limit
    local rem=$((RUN_START + JOB_LIMIT + 240 - $(date +%s)))
    [ "$rem" -lt 120 ] && { echo "::warning::not enough time left to save a checkpoint"; exit 0; }
    IN_TIMEOUT=1 exec timeout "$rem" bash "${BASH_SOURCE[0]}" save
  fi
  [ -f "$ROOT/chromium/.titanium_prep_done" ] || { log "no prepared tree, nothing to save"; return 0; }
  save_state "$(cat "$META/next_gen")"
}

cmd_finish() {
  [ -n "$VERSION" ] || die "no version"
  cd "$ROOT/chromium/src" || die "no tree"
  export PATH="$PWD/third_party/jdk/current/bin/:$PATH"
  export ANDROID_HOME="$PWD/third_party/android_sdk/public"
  mkdir -p out/release
  local apk; apk=$(find out/Default/apks -name 'Chrome*.apk' | head -n1)
  [ -n "$apk" ] || die "no APK found in out/Default/apks"
  set_keys
  sign_apk "$apk" "out/release/$VERSION-arm64-v8a.apk"
  rm -rf "$SCRIPT_DIR/keys"
  local name
  name="$VERSION-$(date +%s)-arm64-v8a.apk"
  cp "out/release/$VERSION-arm64-v8a.apk" "$ROOT/chromium/$name"
  mkdir -p "$ROOT/chromium/mapping"
  find out/Default -name '*.mapping' -exec cp -v {} "$ROOT/chromium/mapping/" \;
  out mapping "$ROOT/chromium/mapping"
  out apk "$ROOT/chromium/$name"
  if [ "$PUBLISH" = "true" ]; then
    local tag="v$VERSION" flags=""
    [ "$OFFICIAL" = "true" ] || flags="--prerelease"
    $GH release view "$tag" -R "$REPO" >/dev/null 2>&1 \
      || $GH release create "$tag" -R "$REPO" --title "v$VERSION" $flags \
           --notes "arm64-v8a only. Official build flags: $OFFICIAL. Built in stages on a free GitHub runner."
    $GH release upload "$tag" "$ROOT/chromium/$name" --clobber -R "$REPO"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "$1" in
    build)  cmd_build ;;
    save)   cmd_save ;;
    upload-part) upload_part || exit 1 ;;   # internal: used by `split --filter`
    finish) cmd_finish ;;
    *) die "usage: staged.sh build|save|finish" ;;
  esac
fi
