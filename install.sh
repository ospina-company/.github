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
  # git and gh are required. vale only powers the advisory prose linter, so a
  # failure there must not end onboarding: set -e would otherwise abort the whole
  # run before auth, clone and bootstrap ever happen.
  for pkg in git gh; do
    if have "$pkg"; then say "  ok       $pkg"
    else
      say "  install  $pkg"
      brew install "$pkg" >/dev/null || die "Could not install $pkg. Install it manually, then re-run."
    fi
  done
  if have vale; then say "  ok       vale"
  elif say "  install  vale" && brew install vale >/dev/null 2>&1; then say "  ok       vale"
  else say "  note     vale did not install. Prose linting will not work; everything else will."
  fi
else
  if ! have git; then
    die "git is required.
  Debian/Ubuntu:  sudo apt install git
  Fedora/RHEL:    sudo dnf install git
  Then re-run this command."
  fi
  if ! have gh; then
    die "gh (GitHub CLI) is required.
  Install instructions: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
  Then re-run this command."
  fi
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

WHO=$(gh api user --jq .login 2>/dev/null || true)
if [ -z "$WHO" ]; then
  die "Signed in, but GitHub did not return your username.
  Check your connection and run: gh auth status
  Then re-run this command."
fi

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

# ------------------------------------------------------------- coding agent
step "Coding agent"
say "  T3 Code is the editor this workflow uses. Claude Code and Codex are the"
say "  agents that run inside it. You need T3 Code and at least one agent."
say "  You bring your own Claude or Codex subscription; Ospina does not provide one."
say ""

ask_yes_no() {
  # Default yes: this is how the workflow is set up, so the common answer
  # should be the one you get by pressing Enter.
  printf '%s [Y/n] ' "$1"
  read -r _a </dev/tty || _a=""
  case "$_a" in ''|[Yy]*) return 0 ;; *) return 1 ;; esac
}

have_t3()     { have t3 || ls -d /Applications/T3\ Code*.app >/dev/null 2>&1; }
have_claude() { have claude; }
have_codex()  { have codex; }

install_t3() {
  if [ "$PLATFORM" = mac ] && have brew; then brew install --cask t3-code >/dev/null 2>&1
  else say "          open https://t3.codes/download"; return 1; fi
}
install_claude() {
  if [ "$PLATFORM" = mac ] && have brew; then brew install --cask claude-code >/dev/null 2>&1
  else
    # Download first, then run, so the script that executes is a file that can
    # be inspected afterwards rather than a stream piped straight into a shell.
    _ci="${TMPDIR:-/tmp}/claude-install.$$.sh"
    if curl -fsSL https://claude.ai/install.sh -o "$_ci"; then
      bash "$_ci" >/dev/null 2>&1; _rc=$?
      rm -f "$_ci"; return $_rc
    else
      return 1
    fi
  fi
}
install_codex() {
  if have brew; then brew install codex >/dev/null 2>&1
  elif have npm; then npm install -g @openai/codex >/dev/null 2>&1
  else say "          needs Homebrew or npm; see https://github.com/openai/codex"; return 1; fi
}

for _agent in "T3 Code|have_t3|install_t3" "Claude Code|have_claude|install_claude" "Codex|have_codex|install_codex"; do
  _name=${_agent%%|*}; _rest=${_agent#*|}; _test=${_rest%%|*}; _inst=${_rest#*|}
  if $_test; then printf '  ok       %-14s already installed\n' "$_name"; continue; fi
  printf '  --       %-14s not found\n' "$_name"
  if ask_yes_no "           Install $_name?"; then
    say "          installing $_name, this can take a minute..."
    if $_inst || $_test; then printf '  ok       %-14s installed\n' "$_name"
    else printf '  note     %-14s not installed; a new terminal may be needed\n' "$_name"; fi
  else
    say "           skipped. Re-run this command later and it will offer again."
  fi
done
say ""


# ---------------------------------------------------------------- workspace
step "Workspace location"

# Offer places that already exist on this machine rather than inventing one.
if [ -n "${OSPINA_WORKSPACE:-}" ]; then
  WS="$OSPINA_WORKSPACE"
  say "  using OSPINA_WORKSPACE=$WS"
else
  # Newline-delimited in a temp file, not a space-separated string: a
  # candidate like "~/My Projects/Ospina" would otherwise word-split into two.
  CANDFILE=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/ospina-cands.$$")
  : > "$CANDFILE"
  add_cand() {
    # Skip anything a sync client owns: git and sync both write .git.
    case "$1" in
      *iCloud*|*Dropbox*|*"Google Drive"*|*OneDrive*) return 0 ;;
    esac
    # macOS filesystems are case-insensitive, so ~/Projects and ~/projects are
    # one directory that pwd will happily report under either name. Compare the
    # inode, which is the only thing that actually settles it.
    _id=$(ls -di "$(dirname "$1")" 2>/dev/null | awk '{print $1}')
    while IFS= read -r existing; do
      [ -n "$existing" ] || continue
      _eid=$(ls -di "$(dirname "$existing")" 2>/dev/null | awk '{print $1}')
      [ -n "$_id" ] && [ "$_eid" = "$_id" ] && return 0
    done < "$CANDFILE"
    printf '%s\n' "$1" >> "$CANDFILE"
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

  if [ "$pick" -eq "$pick" ] 2>/dev/null; then
    # Numeric input is a menu choice. A number outside the menu is a mistake,
    # not a directory named "9".
    if [ "$pick" -ge 1 ] && [ "$pick" -le "$N" ]; then
      i=0
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        i=$((i+1)); [ "$i" -eq "$pick" ] && WS="$c"
      done < "$CANDFILE"
    elif [ "$pick" -eq "$((N+1))" ]; then
      printf '  Full path: '
      read -r WS </dev/tty || WS=""
      [ -z "$WS" ] && die "No path given."
    else
      die "$pick is not one of the choices. Re-run and pick 1 to $((N+1))."
    fi
  else
    # Non-numeric input is treated as a literal path.
    WS="$pick"
  fi
fi
rm -f "${CANDFILE:-}" 2>/dev/null || true
WS="${WS/#\~/$HOME}"
# Apply the sync-folder rule to every route into WS, not just the menu: a path
# from OSPINA_WORKSPACE or typed by hand can land in a synced folder too.
case "$WS" in
  *iCloud*|*Dropbox*|*"Google Drive"*|*OneDrive*)
    die "That workspace is inside a cloud-synced folder.
  Sync clients and git both write to .git and will corrupt the repositories.
  Choose a path outside iCloud, Dropbox, Google Drive and OneDrive." ;;
esac
mkdir -p "$WS"
WS=$(CDPATH= cd -- "$WS" && pwd)
say "  workspace: $WS"

step "Handbook"
if [ -d "$WS/handbook/.git" ]; then
  say "  ok       already cloned, updating"
  # A stale handbook still bootstraps, so this is deliberately not fatal. Do not
  # guess the cause: diverged history, credentials and network all land here.
  git -C "$WS/handbook" pull -q --ff-only \
    || say "  ${DIM}could not update the handbook; continuing with the existing copy${RESET}"
else
  gh repo clone ospina-company/handbook "$WS/handbook" -- -q \
    || die "Could not clone the handbook into $WS/handbook.
  Check your connection and that you still have access:
    gh repo view ospina-company/handbook
  Then re-run this command."
  say "  cloned   $WS/handbook"
fi

# ---------------------------------------------------------------- handoff
step "Running bootstrap"
say ""
exec sh "$WS/handbook/bootstrap.sh" --no-login "$@"
