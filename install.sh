#!/usr/bin/env bash
# Ospina workspace installer — macOS and Linux.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ospina-company/.github/main/install.sh)"
#
# Installs git, gh and vale, signs you in to GitHub, clones the handbook, and
# hands off to handbook/bootstrap.sh, which clones every Ospina repo your
# GitHub account can see and configures your agent.
#
# Read before running. It is short on purpose.
# Safe to re-run: every step checks before it acts.

set -euo pipefail

BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

case "$(uname -s)" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      die "This installer covers macOS and Linux. On Windows use install.ps1." ;;
esac

say ""
say "${BOLD}Ospina workspace setup${RESET}"
say "${DIM}You will need a GitHub account that has been added to the ospina-company org.${RESET}"

# ----------------------------------------------------------------- packages
step "Checking tools"

if [ "$PLATFORM" = mac ]; then
  if ! have brew; then
    say "Homebrew is required and not installed."
    say "Install it, then re-run this command:"
    say "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    die "Homebrew missing"
  fi
  for pkg in git gh vale; do
    if have "$pkg"; then say "  ok       $pkg"; else say "  install  $pkg"; brew install "$pkg" >/dev/null; fi
  done
else
  have git || die "git is required. Install it with your package manager, then re-run."
  have gh  || die "gh is required. See https://github.com/cli/cli#installation, then re-run."
  say "  ok       git, gh"
  have vale || say "  ${DIM}note: vale not found. Optional, but prose linting will not work.${RESET}"
fi

# --------------------------------------------------------------------- auth
step "GitHub sign-in"
if gh auth status >/dev/null 2>&1; then
  say "  ok       signed in as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
  say "  You need a GitHub account for this. It is free."
  say ""
  printf '  Do you already have a GitHub account? (y/n) '
  read -r has </dev/tty || has=""
  case "$has" in
    [Yy]*) : ;;
    *)
      say ""
      say "  Opening the GitHub signup page. Create the account, then come back"
      say "  here and run this same command again."
      (command -v open >/dev/null && open "https://github.com/signup") 2>/dev/null \
        || (command -v xdg-open >/dev/null && xdg-open "https://github.com/signup") 2>/dev/null \
        || say "  https://github.com/signup"
      say ""
      say "  Command to re-run:"
      say "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/ospina-company/.github/main/install.sh)\""
      exit 0
      ;;
  esac
  say ""
  say "  A browser window will open. Choose GitHub.com, then HTTPS."
  gh auth login || die "GitHub sign-in did not complete. Run 'gh auth login' and try again."
fi

WHO=$(gh api user --jq .login 2>/dev/null || echo '?')

if ! gh repo view ospina-company/handbook --json name >/dev/null 2>&1; then
  # "Not in the org" and "in the org but no handbook" need different asks.
  if gh api "orgs/ospina-company/members/$WHO" >/dev/null 2>&1; then IN_ORG=1; else IN_ORG=0; fi
  say ""
  say "  ------------------------------------------------------------------"
  say "  You are signed in as: $WHO"
  say ""
  if [ "$IN_ORG" -eq 0 ]; then
    say "  You are not a member of the ospina-company organization yet."
    say "  This is expected on a first run. Two steps:"
    say ""
    say "    1. Send Carlos your GitHub username:  $WHO"
    say "       (hi@ospinacompany.com)"
    say ""
    say "    2. He sends an invite. Accept it here:"
    say "       https://github.com/orgs/ospina-company/invitation"
  else
    say "  You ARE in the ospina-company organization, but your team does not"
    say "  have access to the 'handbook' repository. Setup cannot continue"
    say "  without it: handbook holds the conventions, the agent skills and"
    say "  this bootstrap itself."
    say ""
    say "  This is a blocker, not something you can work around."
    say ""
    say "  Ask Carlos to add 'handbook' with Read access to your team:"
    say "    hi@ospinacompany.com"
    say "    https://github.com/orgs/ospina-company/teams"
  fi
  say ""
  say "  Then run this same command again and it will finish the setup."
  say "  ------------------------------------------------------------------"
  exit 0
fi
say "  ok       access to Ospina repositories confirmed"

# ---------------------------------------------------------------- workspace
step "Workspace location"

# Offer places that already exist on this machine rather than inventing one.
if [ -n "${OSPINA_WORKSPACE:-}" ]; then
  WS="$OSPINA_WORKSPACE"
  say "  using OSPINA_WORKSPACE=$WS"
else
  CANDS=""
  add_cand() {
    # Skip anything a sync client owns: git and sync both write .git.
    case "$1" in
      *iCloud*|*Dropbox*|*"Google Drive"*|*OneDrive*) return 0 ;;
    esac
    # macOS filesystems are case-insensitive, so ~/Projects and ~/projects are
    # one directory that pwd will happily report under either name. Compare the
    # inode, which is the only thing that actually settles it.
    _id=$(ls -di "$(dirname "$1")" 2>/dev/null | awk '{print $1}')
    for existing in $CANDS; do
      _eid=$(ls -di "$(dirname "$existing")" 2>/dev/null | awk '{print $1}')
      [ -n "$_id" ] && [ "$_eid" = "$_id" ] && return 0
    done
    CANDS="$CANDS $1"
    N=$((N+1))
    printf '    %d) %-44s %s\n' "$N" "$1" "$2"
  }

  say ""
  say "  Where should the Ospina repositories live?"
  say ""
  N=0
  for d in Software/Projects Projects projects Developer dev code repos git src; do
    [ -d "$HOME/$d" ] && add_cand "$HOME/$d/Ospina" "inside your existing $d folder"
  done
  add_cand "$HOME/Ospina" "in your home folder (will be created)"
  say "    $((N+1))) somewhere else, type a path"
  say ""
  printf '  Choice [1]: '
  read -r pick </dev/tty || pick=""
  [ -z "$pick" ] && pick=1

  if [ "$pick" -eq "$pick" ] 2>/dev/null && [ "$pick" -ge 1 ] && [ "$pick" -le "$N" ]; then
    i=0
    for c in $CANDS; do i=$((i+1)); [ "$i" -eq "$pick" ] && WS="$c"; done
  elif [ "$pick" -eq "$((N+1))" ] 2>/dev/null; then
    printf '  Full path: '
    read -r WS </dev/tty || WS=""
    [ -z "$WS" ] && die "No path given."
  else
    WS="$pick"
  fi
fi
WS="${WS/#\~/$HOME}"
mkdir -p "$WS"
WS=$(CDPATH= cd -- "$WS" && pwd)
say "  workspace: $WS"

step "Handbook"
if [ -d "$WS/handbook/.git" ]; then
  say "  ok       already cloned, updating"
  git -C "$WS/handbook" pull -q --ff-only || say "  ${DIM}(local changes, left alone)${RESET}"
else
  gh repo clone ospina-company/handbook "$WS/handbook" -- -q
  say "  cloned   $WS/handbook"
fi

# ---------------------------------------------------------------- handoff
step "Running bootstrap"
say ""
exec sh "$WS/handbook/bootstrap.sh" --no-login "$@"
