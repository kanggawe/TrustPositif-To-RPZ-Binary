#!/usr/bin/env bash
# git-shrink-history.sh — Kecilkan ukuran .git dengan aman (deteksi → bersihkan → GC → (opsional) push)
# (versi perbaikan sintaks)

set -euo pipefail
IFS=$'\n\t'

VERSION="1.4.1"

# Default Config
DRY_RUN=1
THRESHOLD_MB=""
PATHS_TO_REMOVE=()
GLOBS_TO_REMOVE=()
REMOTE_NAME="origin"
DO_PUSH=0
ALLOW_DIRTY=0
DO_BACKUP=0
BACKUP_DIR=""
USE_BFG=""
SKIP_AGGRESSIVE_GC=0

log() { printf "[%%s] %%s\n" "$(date '+%F %T')" "$*"; }
err() { printf "[%%s] [ERROR] %%s\n" "$(date '+%F %T')" "$*" >&2; }

usage() {
  cat <<USAGE
Usage: git-shrink-history.sh [options]
  --threshold MB         Strip blobs > MB
  --path PATH            Remove specific path
  --path-glob GLOB       Remove by glob
  --apply                Apply rewrite
  --push                 Push force to remote
  --remote NAME          Remote name (default: origin)
  --backup               Make backup bundle
  --backup-dir DIR       Bundle dir
  --allow-dirty          Allow dirty tree
  --use-bfg              Force use BFG
  --skip-aggressive-gc   Use normal gc
USAGE
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Perintah '$1' tidak ditemukan"; return 1; }; }

ensure_repo_root() { git rev-parse --show-toplevel >/dev/null 2>&1 || { err "Bukan repo git"; exit 1; }; cd "$(git rev-parse --show-toplevel)"; }

ensure_clean_tree() { (( ALLOW_DIRTY )) && return 0; git diff --quiet && git diff --cached --quiet || { err "Working tree kotor"; exit 1; }; }

ensure_not_shallow() { if [ -f .git/shallow ]; then log "Unshallow fetch..."; git fetch --unshallow --tags || { err "Gagal unshallow"; exit 1; }; fi; }

make_backup_bundle() { local outdir=${BACKUP_DIR:-"$(pwd)/backup-bundles"}; mkdir -p "$outdir"; local stamp=$(date '+%Y%m%d-%H%M%S'); local name=$(basename "$(git rev-parse --show-toplevel)"); local bundle="$outdir/${name}-${stamp}.bundle"; log "Membuat bundle: $bundle"; git bundle create "$bundle" --all; }

analyze_with_filter_repo() {
  log "Analisis filter-repo..."
  rm -rf .git/filter-repo 2>/dev/null || true
  git filter-repo --force --analyze
  local sizes_file=".git/filter-repo/analysis/blob-sizes.txt"
  local map_file=".git/filter-repo/analysis/blob-shas-and-paths.txt"
  if [[ -f "$sizes_file" && -f "$map_file" ]]; then
    awk '{print $1" "$2}' "$sizes_file" | sort -nrk1 | head -30 | while read -r size sha; do
      path=$(grep -m1 "^$sha " "$map_file" | cut -d' ' -f2- || true)
      printf "  %10d bytes  %s  %s\n" "$size" "$sha" "${path:-<no path>}"
    done
  fi
}

parse_args() {
  while (( "$#" )); do
    case "$1" in
      --threshold) THRESHOLD_MB="$2"; shift 2;;
      --path) PATHS_TO_REMOVE+=("$2"); shift 2;;
      --path-glob) GLOBS_TO_REMOVE+=("$2"); shift 2;;
      --apply) DRY_RUN=0; shift;;
      --push) DO_PUSH=1; shift;;
      --remote) REMOTE_NAME="$2"; shift 2;;
      --backup) DO_BACKUP=1; shift;;
      --backup-dir) BACKUP_DIR="$2"; shift 2;;
      --allow-dirty) ALLOW_DIRTY=1; shift;;
      --use-bfg) USE_BFG=1; shift;;
      --skip-aggressive-gc) SKIP_AGGRESSIVE_GC=1; shift;;
      -h|--help) usage; exit 0;;
      *) err "Argumen tidak dikenal: $1"; usage; exit 1;;
    esac
  done
}

build_filter_repo_args() {
  local args=("--force")
  [[ -n "$THRESHOLD_MB" ]] && args+=("--strip-blobs-bigger-than" "${THRESHOLD_MB}M")
  local invert_needed=0
  for p in "${PATHS_TO_REMOVE[@]:-}"; do args+=("--path" "$p"); invert_needed=1; done
  for g in "${GLOBS_TO_REMOVE[@]:-}"; do args+=("--path-glob" "$g"); invert_needed=1; done
  (( invert_needed )) && args+=("--invert-paths")
  printf '%s\n' "${args[@]}"
}

run_filter_repo_apply() {
  local fr_args; mapfile -t fr_args < <(build_filter_repo_args)
  (( ${#fr_args[@]} == 1 )) && { err "Tidak ada kriteria"; exit 1; }
  log "Jalankan git filter-repo: ${fr_args[*]}"
  git filter-repo "${fr_args[@]}"
}

post_cleanup_gc() {
  rm -rf .git/refs/original/ 2>/dev/null || true
  git reflog expire --expire=now --expire-unreachable=now --all
  (( SKIP_AGGRESSIVE_GC )) && git gc --prune=now || git gc --prune=now --aggressive
}

show_size() { du -sh .git 2>/dev/null | awk '{print $1}'; }

push_all() { log "Push force..."; git push "$REMOTE_NAME" --force --all; git push "$REMOTE_NAME" --force --tags || true; }

main() {
  parse_args "$@"
  need_cmd git
  ensure_repo_root
  ensure_clean_tree
  ensure_not_shallow

  size_before=$(show_size || echo "?")
  log ".git sebelum: $size_before"

  (( DO_BACKUP )) && make_backup_bundle

  if command -v git-filter-repo >/dev/null 2>&1; then
    analyze_with_filter_repo
    (( DRY_RUN )) && { log "DRY-RUN selesai"; exit 0; }
    run_filter_repo_apply
  else
    err "git-filter-repo tidak ditemukan, install dulu"
    exit 1
  fi

  post_cleanup_gc
  size_after=$(show_size || echo "?")
  log ".git sesudah: $size_after"

  (( DO_PUSH )) && push_all
  log "Selesai"
}

main "$@"
