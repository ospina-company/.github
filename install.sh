#!/usr/bin/env bash
# Ospina workspace installer — macOS and Linux.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ospina-company/.github/main/install.sh)"
#
# Installs the workstation baseline (Git, Node 24, Python 3.12, document tools
# and T3 Code), signs you in to GitHub, clones the handbook, and hands off to
# handbook/bootstrap.sh, which clones only the Ospina repos your account can
# read and configures your agents.
#
# Read before running. It is short on purpose.
# Safe to re-run: every step checks before it acts.

set -euo pipefail

BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ask_yes_no() {
  # Default yes: this is how the workflow is set up, so the common answer
  # should be the one you get by pressing Enter.
  printf '%s [Y/n] ' "$1"
  read -r _a </dev/tty || _a=""
  case "$_a" in ''|[Yy]*) return 0 ;; *) return 1 ;; esac
}

add_path() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in *":$1:"*) : ;; *) PATH="$1:$PATH"; export PATH ;; esac
}

load_brew() {
  have brew && return 0
  for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$_brew" ]; then
      eval "$("$_brew" shellenv)"
      return 0
    fi
  done
  return 1
}

can_install_homebrew() {
  # Homebrew's supported macOS installer requires sudo access. Starting its
  # prompts on a managed standard account can never succeed, so detect that
  # condition before downloading anything and give the reader the IT handoff.
  groups "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx admin
}

uv_supports_default() {
  have uv && uv python install --help 2>/dev/null | grep -q -- '--default'
}

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
  if ! load_brew; then
    say "  --       Homebrew not found"
    if ! can_install_homebrew; then
      die "Homebrew is required, but this macOS account does not have administrator access.
Ask your device administrator to install Homebrew from https://brew.sh, then re-run."
    fi
    if ! ask_yes_no "           Install Homebrew?"; then
      die "Homebrew is required. Re-run this command when you are ready to install it."
    fi
    _hb=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/homebrew-install.$$")
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$_hb" \
      || die "Could not download the Homebrew installer."
    /bin/bash "$_hb" </dev/tty || die "Homebrew did not install successfully."
    rm -f "$_hb"
    load_brew || die "Homebrew installed but is not callable in this terminal. Open a new terminal and re-run."
    say "  ok       Homebrew installed"
  fi

  brew_formula() {
    _cmd=$1; _pkg=$2; _required=$3
    if have "$_cmd"; then say "  ok       $_cmd"
    else
      say "  install  $_pkg"
      # Do not hide this. A first brew install takes minutes, and with the
      # output suppressed a working install is indistinguishable from a hang.
      say "           this can take a few minutes; brew output follows"
      if brew install "$_pkg" && { have "$_cmd" || [ "$_pkg" = node@24 ]; }; then :
      elif [ "$_required" = required ]; then
        die "Could not install $_pkg. Install it manually, then re-run."
      else
        say "  note     $_pkg did not install. The related quality checks will not work."
      fi
    fi
  }

  brew_formula git git required
  brew_formula gh gh required
  brew_formula vale vale optional
  brew_formula uv uv required
  brew_formula pdftotext poppler required

  # uv 0.5 introduced the --default behavior used below. Presence alone does
  # not make an old uv compatible, so upgrade/replace it before proceeding.
  if ! uv_supports_default; then
    say "  upgrade  uv (the installed version lacks 'python install --default')"
    brew upgrade uv || brew install uv || die "Could not install a current uv."
    add_path "$(brew --prefix)/bin"
    hash -r
    uv_supports_default || die "A conflicting old uv is still first on PATH. Remove it, then re-run."
  fi

  _node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
  if [ "$_node_major" != 24 ]; then
    say "  install  Node 24 LTS"
    say "           this can take a few minutes; brew output follows"
    brew install node@24 || die "Could not install Node 24."
    # node@24 is versioned and therefore keg-only. Link it deliberately: Node
    # 25+ breaks repositories that cap their supported range below 25.
    brew link --overwrite --force node@24 || true
    add_path "$(brew --prefix node@24)/bin"
  fi
  _node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
  [ "$_node_major" = 24 ] || die "Node 24 installed but is not active. Open a new terminal and re-run."
  say "  ok       node $(node --version)"

  if ! have soffice && [ ! -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]; then
    say "  install  LibreOffice"
    say "           this is a large download; brew output follows"
    brew install --cask libreoffice || die "Could not install LibreOffice."
  fi
  if [ -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf /Applications/LibreOffice.app/Contents/MacOS/soffice "$HOME/.local/bin/soffice"
    add_path "$HOME/.local/bin"
  fi
  have soffice || die "LibreOffice installed but soffice is not callable. Open a new terminal and re-run."
  say "  ok       soffice"
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
  if have node; then
    _linux_node_major=$(node --version 2>/dev/null | sed 's/^v//;s/\..*//' || true)
    [ "$_linux_node_major" = 24 ] \
      || say "  ${DIM}note: Node 24 is required, but Node ${_linux_node_major:-unknown} is active.${RESET}"
  else
    say "  ${DIM}note: Node 24 is required. Install it from https://nodejs.org, then re-run.${RESET}"
  fi
  have uv || say "  ${DIM}note: uv is required. Install it from https://docs.astral.sh/uv/, then re-run.${RESET}"
  have soffice || say "  ${DIM}note: LibreOffice is required for document verification.${RESET}"
  have pdftotext || say "  ${DIM}note: Poppler is required for PDF verification.${RESET}"
fi

# Node and Python are workstation capabilities, not project-global dependency
# buckets. Corepack selects each repo's pinned pnpm; uv selects its pinned
# Python and creates isolated environments.
if have node; then
  if ! have corepack && have npm; then
    say "  install  corepack"
    npm install -g corepack \
      || say "  note     Corepack did not install. pnpm repositories will not run yet."
  fi
  if have corepack; then
    mkdir -p "$HOME/.local/bin"
    if corepack enable --install-directory "$HOME/.local/bin"; then
      add_path "$HOME/.local/bin"
      say "  ok       corepack $(corepack --version 2>/dev/null || echo present)"
    else
      say "  note     Corepack could not enable pnpm. Setup will continue."
    fi
  else
    say "  note     Corepack is missing. Setup will continue; pnpm repos need it."
  fi
fi

if have uv; then
  uv_supports_default || die "uv is too old; version 0.5 or newer is required."
  say "  install  Python 3.12 (managed by uv)"
  uv python install 3.12 --default || die "uv could not install Python 3.12."
  _uv_bin=$(uv python dir --bin 2>/dev/null || true)
  [ -n "$_uv_bin" ] && add_path "$_uv_bin"
  if uv python find 3.12 >/dev/null 2>&1; then
    _python_minor=$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)
    [ "$_python_minor" = 3.12 ] \
      || die "Python 3.12 is installed, but the 'python' command resolves to ${_python_minor:-nothing}. Open a new terminal and re-run."
    say "  ok       Python $(python -c 'import platform; print(platform.python_version())')"
  else
    die "Python 3.12 was requested but uv cannot find it."
  fi
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

have_t3()     { have t3 || ls -d /Applications/T3\ Code*.app >/dev/null 2>&1; }
have_claude() { have claude; }
have_codex()  { have codex; }

install_t3() {
  if [ "$PLATFORM" = mac ] && have brew; then brew install --cask t3-code
  else say "          open https://t3.codes/download"; return 1; fi
}
install_claude() {
  if [ "$PLATFORM" = mac ] && have brew; then brew install --cask claude-code
  else
    # Download first, then run, so the script that executes is a file that can
    # be inspected afterwards rather than a stream piped straight into a shell.
    _ci="${TMPDIR:-/tmp}/claude-install.$$.sh"
    if curl -fsSL https://claude.ai/install.sh -o "$_ci"; then
      bash "$_ci"; _rc=$?
      rm -f "$_ci"; return $_rc
    else
      return 1
    fi
  fi
}
install_codex() {
  if have brew; then brew install --cask codex
  elif have npm; then npm install -g @openai/codex
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

_signed_in=0
if have claude; then
  if claude auth status >/dev/null 2>&1; then
    say "  ok       Claude Code signed in"
    _signed_in=1
  elif ask_yes_no "           Sign in to Claude Code now?"; then
    claude auth login || say "  note     Claude Code sign-in did not complete"
    claude auth status >/dev/null 2>&1 && _signed_in=1
  fi
fi
if have codex; then
  if codex login status >/dev/null 2>&1; then
    say "  ok       Codex signed in"
    _signed_in=1
  elif ask_yes_no "           Sign in to Codex now?"; then
    codex login || say "  note     Codex sign-in did not complete"
    codex login status >/dev/null 2>&1 && _signed_in=1
  fi
fi
[ "$_signed_in" -eq 1 ] \
  || say "  note     Sign in to at least one agent before starting work in T3 Code."
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
