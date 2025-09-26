#!/usr/bin/env bash

# Create a minimal arXiv submission package from a LaTeX project.
# - Defaults to using camera_ready.tex as the main file
# - Recursively discovers \input, \include, \includegraphics
# - Keeps local .sty/.cls used if present in the directory
# - Keeps the main .bbl (BibTeX) file if present (recommended for arXiv)
# - Copies only the necessary files into arxiv_submission/ by default
# - Supports a dry-run and an optional in-place prune of unneeded files
# - Optionally runs arxiv_latex_cleaner on the output folder
#
# Usage:
#   ./clean_arxiv.sh [options] [MAIN_TEX]
#
# Options:
#   -n, --dry-run        Show what would be kept/removed; do not modify files
#   -o, --out DIR        Output directory (default: arxiv_submission)
#       --inplace        Instead of copying to out dir, delete unneeded files in-place
#       --force          Overwrite output directory if it exists
#       --zip            Create a zip archive of the output directory
#   -c, --run-cleaner    Run arxiv_latex_cleaner on the output (default: auto if found)
#       --no-cleaner     Do not run arxiv_latex_cleaner
#       --cleaner-args S Pass extra args to arxiv_latex_cleaner (quoted string)
#   -h, --help           Show help

set -euo pipefail

MAIN_TEX="camera_ready.tex"
OUT_DIR="submission"
DRY_RUN=false
INPLACE=false
FORCE=false
MAKE_ZIP=false
RUN_CLEANER="auto" # values: auto|true|false
CLEANER_ARGS=""

print_help() {
  sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//' | sed '1,/^$/d' | sed '/^set -euo pipefail/,$d'
}

log() { echo "[clean-arxiv] $*"; }

err() { echo "[clean-arxiv][error] $*" >&2; }

contains() { # contains item list...
  local item="$1"; shift
  for x in "$@"; do [[ "$x" == "$item" ]] && return 0; done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    -o|--out) OUT_DIR="${2:-}"; shift 2 ;;
    --inplace) INPLACE=true; shift ;;
    --force) FORCE=true; shift ;;
    --zip) MAKE_ZIP=true; shift ;;
    -c|--run-cleaner) RUN_CLEANER="true"; shift ;;
    --no-cleaner) RUN_CLEANER="false"; shift ;;
    --cleaner-args) CLEANER_ARGS="${2:-}"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    *) MAIN_TEX="$1"; shift ;;
  esac
done

if [[ ! -f "$MAIN_TEX" ]]; then
  err "Main TeX file not found: $MAIN_TEX"
  exit 1
fi

if $INPLACE && $MAKE_ZIP; then
  err "--inplace cannot be combined with --zip"
  exit 1
fi

# Tools
if ! command -v rg >/dev/null 2>&1; then
  err "ripgrep (rg) is required for fast, reliable parsing. Please install rg."
  exit 1
fi

declare -A KEEP=()
declare -A SEEN_TEX=()

add_keep() {
  local p="$1"
  # Normalize leading ./
  p="${p#./}"
  KEEP["$p"]=1
}

queue=()
queue+=("$MAIN_TEX")

# Discover dependencies recursively from TeX files
while [[ ${#queue[@]} -gt 0 ]]; do
  f="${queue[0]}"; queue=("${queue[@]:1}")
  [[ -f "$f" ]] || continue
  f_rel="${f#./}"
  if [[ -n "${SEEN_TEX[$f_rel]:-}" ]]; then
    continue
  fi
  SEEN_TEX["$f_rel"]=1
  add_keep "$f_rel"

  # \input{...} and \include{...}
  while IFS= read -r inc; do
    # inc like path or path.ext
    cand="$inc"
    if [[ -f "$cand" ]]; then
      queue+=("$cand")
      continue
    fi
    # Try adding .tex
    if [[ -f "$cand.tex" ]]; then
      queue+=("$cand.tex")
      continue
    fi
  done < <(sed 's/%.*$//' "$f_rel" | rg -No '\\(input|include)\{([^}]+)\}' - | sed -E 's/.*\{([^}]+)\}.*/\1/')

  # \includegraphics{...}
  while IFS= read -r g; do
    if [[ -f "$g" ]]; then
      add_keep "$g"
    else
      # No extension provided – try common ones
      for ext in .pdf .png .jpg .jpeg .eps; do
        if [[ -f "$g$ext" ]]; then
          add_keep "$g$ext"
          break
        fi
      done
    fi
  done < <(sed 's/%.*$//' "$f_rel" | rg -No '\\includegraphics(?:\[[^\]]*\])?\{([^}]+)\}' - | sed -E 's/.*\{([^}]+)\}.*/\1/')

  # Local style files used via \usepackage{...}
  while IFS= read -r pkg; do
    # Split comma-separated list
    while IFS= read -r p; do
      p_trim="${p// /}"
      [[ -z "$p_trim" ]] && continue
      # If a local .sty exists, include it
      if [[ -f "$p_trim.sty" ]]; then
        add_keep "$p_trim.sty"
      fi
    done < <(echo "$pkg" | tr ',' '\n')
  done < <(sed 's/%.*$//' "$f_rel" | rg -No '\\usepackage(?:\[[^\]]*\])?\{([^}]+)\}' - | sed -E 's/.*\{([^}]+)\}.*/\1/')

  # Local class file via \documentclass{...}
  while IFS= read -r cls; do
    if [[ -f "$cls.cls" ]]; then
      add_keep "$cls.cls"
    fi
  done < <(sed 's/%.*$//' "$f_rel" | rg -No '\\documentclass(?:\[[^\]]*\])?\{([^}]+)\}' - | sed -E 's/.*\{([^}]+)\}.*/\1/')
done

# Keep the main .bbl if present (arXiv prefers pre-generated bibliography)
BASE="$(basename "$MAIN_TEX" .tex)"
if [[ -f "$BASE.bbl" ]]; then
  add_keep "$BASE.bbl"
fi

# If a local .bst for the chosen style exists, include it
while IFS= read -r bst; do
  if [[ -f "$bst.bst" ]]; then
    add_keep "$bst.bst"
  fi
done < <(sed 's/%.*$//' "$MAIN_TEX" | rg -No '\\bibliographystyle\{([^}]+)\}' - | sed -E 's/.*\{([^}]+)\}.*/\1/')

# Always keep the main tex even if it wasn't discovered (already added)

# Compute all files in repo (excluding VCS and output dir)
mapfile -t ALL_FILES < <(find . -type f \( -name .git -prune -o -name "$OUT_DIR" -prune -o -print \) | sed 's#^\./##')

# Build keep list array
KEEP_LIST=()
for k in "${!KEEP[@]}"; do
  # Keep only existing files
  if [[ -f "$k" ]]; then
    KEEP_LIST+=("$k")
  fi
done

# Sort lists for stable output
IFS=$'\n' KEEP_LIST=($(sort <<<"${KEEP_LIST[*]:-}"))
unset IFS

# Derive remove list
REMOVE_LIST=()
for f in "${ALL_FILES[@]}"; do
  # Skip files under output dir and typical aux/logs inside output dir
  if [[ "$f" == "$OUT_DIR"/* ]]; then
    continue
  fi
  if contains "$f" "${KEEP_LIST[@]:-}"; then
    continue
  fi
  # Do not touch this script
  if [[ "$f" == "clean_arxiv.sh" ]]; then
    continue
  fi
  # Skip common LaTeX aux files from being considered (they won't be copied anyway)
  case "$f" in
    *.aux|*.log|*.out|*.synctex.gz|*.toc|*.blg|*.lot|*.lof) ;; # will be removed if --inplace
  esac
  REMOVE_LIST+=("$f")
done

log "Main: $MAIN_TEX"
log "Files to keep (${#KEEP_LIST[@]}):"
for k in "${KEEP_LIST[@]}"; do echo "  $k"; done

log "Files to remove (${#REMOVE_LIST[@]}):"
for r in "${REMOVE_LIST[@]}"; do echo "  $r"; done

if $DRY_RUN; then
  log "Dry-run complete. No changes made."
  exit 0
fi

if $INPLACE; then
  log "Pruning in-place..."
  for r in "${REMOVE_LIST[@]}"; do
    if [[ -f "$r" ]]; then
      log "Deleting: $r"
      rm -f -- "$r"
    fi
  done
  log "Done pruning."
  exit 0
fi

# Else, copy to OUT_DIR
if [[ -e "$OUT_DIR" ]]; then
  if ! $FORCE; then
    err "Output directory '$OUT_DIR' already exists. Use --force to overwrite."
    exit 1
  fi
  log "Removing existing output directory '$OUT_DIR'"
  rm -rf -- "$OUT_DIR"
fi

log "Creating output directory: $OUT_DIR"
mkdir -p "$OUT_DIR"

for src in "${KEEP_LIST[@]}"; do
  dest="$OUT_DIR/$src"
  log "Copy: $src -> $dest"
  install -D "$src" "$dest"
done

log "Submission package created at: $OUT_DIR"

run_cleaner_if_requested() {
  local run="$1"; shift || true
  local outdir="$1"; shift || true
  local args="$1"; shift || true

  if [[ "$run" == "false" ]]; then
    log "Skipping arxiv_latex_cleaner (disabled)."
    return 0
  fi

  # Resolve whether the cleaner is available
  local cleaner_cmd=""
  if command -v arxiv_latex_cleaner >/dev/null 2>&1; then
    cleaner_cmd="arxiv_latex_cleaner"
  elif command -v arxiv-latex-cleaner >/dev/null 2>&1; then
    cleaner_cmd="arxiv-latex-cleaner"
  fi

  if [[ "$run" == "true" ]]; then
    if [[ -z "$cleaner_cmd" ]]; then
      err "arxiv_latex_cleaner not found. Install with: pip install arxiv-latex-cleaner"
      return 1
    fi
  elif [[ "$run" == "auto" ]]; then
    if [[ -z "$cleaner_cmd" ]]; then
      log "arxiv_latex_cleaner not found; skipping (auto)."
      return 0
    fi
  fi

  log "Running $cleaner_cmd on '$outdir' ${args:+with args: $args}"
  "$cleaner_cmd" "$outdir" ${args}
}

run_cleaner_if_requested "$RUN_CLEANER" "$OUT_DIR" "$CLEANER_ARGS" || true

if $MAKE_ZIP; then
  zip_name="${OUT_DIR%/}.zip"
  log "Creating zip: $zip_name"
  (cd "$OUT_DIR" && zip -q -r "../$zip_name" .)
  log "Zip created: $zip_name"
fi

log "All done."
