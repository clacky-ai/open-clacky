# Safe rm shell function — sourced by Clacky::Tools::Terminal at the top
# of every interactive PTY session. See terminal.rb (SAFE_RM_PATH /
# install_marker) for rationale.
#
# Defines a `rm` function that moves files to $CLACKY_TRASH_DIR instead
# of deleting them, so deletions can be recovered via `trash_manager`.
# The metadata sidecar schema matches
# Clacky::Tools::Security::Replacer#create_delete_metadata so
# `trash_manager list/restore` keeps working unchanged.
#
# Covers: direct `rm ...` calls in the interactive shell, including
#   multi-line commands, heredocs (heredoc bodies no longer trigger
#   the rewriter), and shell glob expansion.
# Does NOT cover: `command rm`, `/bin/rm` (absolute path), `xargs rm`,
#   `find -exec rm`, and child scripts — these bypass shell functions
#   by design. This is the same coverage the old static Ruby rewriter
#   had; it could not see inside those either.

rm() {
  # Parse args: respect `--`, collect flag-like and path-like args.
  local __dd=0
  local -a __paths=() __flags=()
  local __a
  for __a in "$@"; do
    if [ "$__dd" = "1" ]; then
      __paths+=("$__a")
    elif [ "$__a" = "--" ]; then
      __dd=1
    elif [ "${__a:0:1}" = "-" ] && [ -n "${__a:1}" ]; then
      __flags+=("$__a")
    else
      __paths+=("$__a")
    fi
  done

  # Trash dir is provisioned by the Ruby side via env.
  local __trash="${CLACKY_TRASH_DIR:-}"
  if [ -z "$__trash" ]; then
    echo "[clacky-rm] CLACKY_TRASH_DIR not set; refusing to rm" >&2
    return 1
  fi
  mkdir -p "$__trash" 2>/dev/null || true

  # Safety: refuse catastrophic targets (pre-expansion by the shell).
  local __p __norm
  for __p in ${__paths[@]+"${__paths[@]}"}; do
    __norm="${__p%/}"
    [ -z "$__norm" ] && __norm="/"
    case "$__norm" in
      /|/root|/etc|/usr|/bin|/sbin|/var)
        echo "[clacky-rm] refused dangerous target: $__p" >&2
        return 1
        ;;
    esac
    if [ "$__norm" = "$HOME" ] || [ "$__p" = "~" ]; then
      echo "[clacky-rm] refused dangerous target: $__p" >&2
      return 1
    fi
  done

  # `-f` semantics: suppress "no such file" errors.
  local __has_f=0 __f
  for __f in ${__flags[@]+"${__flags[@]}"}; do
    case "$__f" in *f*) __has_f=1 ;; esac
  done

  local __rc=0 __base __ts __dest __abs __size __mode __ext __now
  for __p in ${__paths[@]+"${__paths[@]}"}; do
    if [ ! -e "$__p" ] && [ ! -L "$__p" ]; then
      if [ "$__has_f" = "0" ]; then
        echo "rm: $__p: No such file or directory" >&2
        __rc=1
      fi
      continue
    fi
    __base="$(basename -- "$__p")"
    __ts="$(date +%Y%m%d_%H%M%S_%N 2>/dev/null || date +%Y%m%d_%H%M%S)"
    __dest="$__trash/${__base}_deleted_${__ts}"
    # Resolve absolute path for metadata BEFORE mv (path won't exist after).
    if [ -d "$__p" ]; then
      __abs="$(cd "$__p" 2>/dev/null && pwd)" || __abs="$__p"
    else
      __abs="$(cd "$(dirname -- "$__p")" 2>/dev/null && pwd)/$(basename -- "$__p")" || __abs="$__p"
    fi
    # Size / mode best-effort; ignore for dirs or on failure.
    __size="$(stat -f%z "$__p" 2>/dev/null || stat -c%s "$__p" 2>/dev/null || echo 0)"
    __mode="$(stat -f%Lp "$__p" 2>/dev/null || stat -c%a "$__p" 2>/dev/null || echo 644)"
    case "$__base" in
      *.*) __ext=".${__base##*.}" ;;
      *)   __ext="" ;;
    esac
    __now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
    if command mv -- "$__p" "$__dest" 2>/dev/null; then
      # Metadata sidecar — schema matches
      # Clacky::Tools::Security::Replacer#create_delete_metadata so
      # `trash_manager list/restore` continue to work.
      printf '{"original_path":"%s","trash_directory":"%s","deleted_at":"%s","deleted_by":"clacky_rm_shell","file_size":%s,"file_type":"%s","file_mode":"%s"}\n' \
        "$__abs" "$__trash" "$__now" "${__size:-0}" "$__ext" "${__mode:-644}" \
        > "$__dest.metadata.json" 2>/dev/null || true
    else
      echo "rm: failed to move $__p to trash" >&2
      __rc=1
    fi
  done
  return $__rc
}
