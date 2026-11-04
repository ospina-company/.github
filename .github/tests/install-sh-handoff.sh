#!/usr/bin/env bash
# Runs install.sh end to end with stub GitHub and agent commands and a fixture
# handbook whose bootstrap.sh records how it was called. Proves a re-run finds
# an existing setup, never prompts for a workspace, and hands off with --update;
# a first run and an older bootstrap get no --update.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; sed 's/^/  | /' "$T/out" >&2 || true; exit 1; }

mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env sh
case "$1 $2" in
  "auth status"|"repo view") exit 0 ;;
  "api user") echo tester; exit 0 ;;
  "repo clone") git clone -q "$FIXTURE_ORIGIN" "$4" && \
                git -C "$4" remote set-url origin https://github.com/ospina-company/handbook.git && \
                git -C "$4" config url."$FIXTURE_ORIGIN".insteadOf https://github.com/ospina-company/handbook.git
                exit $? ;;
esac
exit 1
GH
for agent in t3 claude codex; do printf '#!/usr/bin/env sh\nexit 0\n' > "$T/bin/$agent"; done
chmod +x "$T/bin"/*

# The fixture handbook: a bootstrap that records its arguments.
make_origin() {
  # $1 = origin dir, $2 = bootstrap body
  rm -rf "$T/src" "$1"
  mkdir -p "$T/src"
  printf '%s\n' "$2" > "$T/src/bootstrap.sh"
  git -C "$T/src" init -q -b main
  git -C "$T/src" -c user.name=t -c user.email=t@example.com add -A
  git -C "$T/src" -c user.name=t -c user.email=t@example.com commit -qm fixture
  git clone -q --bare "$T/src" "$1"
}
CURRENT='#!/bin/sh
# case "$arg" in --update) UPDATE=1 ;; esac
printf "%s\n" "$*" > "$(dirname "$0")/args.txt"'
OLDER='#!/bin/sh
printf "%s\n" "$*" > "$(dirname "$0")/args.txt"'
make_origin "$T/origin.git" "$CURRENT"
export FIXTURE_ORIGIN="$T/origin.git"

run_installer() {
  rc=0
  HOME="$T/home" PATH="$T/bin:$PATH" GIT_TERMINAL_PROMPT=0 OSPINA_HANDBOOK='' \
    bash "$ROOT/install.sh" < /dev/null > "$T/out" 2>&1 || rc=$?
}

# First run: no setup anywhere, workspace given explicitly. No --update.
WS="$T/first/Ospina"
OSPINA_WORKSPACE="$WS" run_installer
[ "$rc" -eq 0 ] || fail "first run exited $rc"
[ "$(cat "$WS/handbook/args.txt")" = "--no-login" ] || fail "first run passed: $(cat "$WS/handbook/args.txt")"

# Re-run: the profile bootstrap wrote names the setup. No prompt, --update.
printf "export OSPINA_HANDBOOK='%s'\n" "$WS/handbook" > "$T/home/.zshrc"
rm -f "$WS/handbook/args.txt"
run_installer
[ "$rc" -eq 0 ] || fail "re-run exited $rc"
grep -Fq "found your existing setup at $WS" "$T/out" || fail "re-run did not report the existing setup"
if grep -Fq 'Where should the Ospina repositories live?' "$T/out"; then fail "re-run asked for a workspace"; fi
[ "$(cat "$WS/handbook/args.txt")" = "--no-login --update" ] || fail "re-run passed: $(cat "$WS/handbook/args.txt")"

# A record pointing at a checkout not named handbook is not trusted, and its
# sibling handbook is not run in its place.
mkdir -p "$T/home/.config/ospina-handbook/bootstrap-state"
git clone -q "$T/origin.git" "$T/other/custom"
git -C "$T/other/custom" remote set-url origin https://github.com/ospina-company/handbook.git
printf '%s\n' "$T/other/custom" > "$T/home/.config/ospina-handbook/bootstrap-state/handbook-dir"
rm -f "$WS/handbook/args.txt"
run_installer
[ "$rc" -eq 0 ] || fail "run with an untrusted record exited $rc"
grep -Fq "found your existing setup at $WS" "$T/out" || fail "an untrusted record displaced the real setup"
[ ! -e "$T/other/args.txt" ] && [ ! -e "$T/other/custom/args.txt" ] || fail "an untrusted checkout ran"
rm "$T/home/.config/ospina-handbook/bootstrap-state/handbook-dir"

# A handbook that predates --update gets the standard setup.
make_origin "$T/origin.git" "$OLDER"
rm -rf "$WS/handbook"
OSPINA_WORKSPACE="$WS" run_installer
[ "$rc" -eq 0 ] || fail "setup with an older bootstrap exited $rc"
rm -f "$WS/handbook/args.txt"
run_installer
[ "$rc" -eq 0 ] || fail "re-run with an older bootstrap exited $rc"
[ "$(cat "$WS/handbook/args.txt")" = "--no-login" ] || fail "an older bootstrap was given: $(cat "$WS/handbook/args.txt")"
grep -Fq 'this handbook predates updates' "$T/out" || fail "the older-bootstrap fallback was not explained"

# A bootstrap.sh that is a link to a script elsewhere is never run.
mkdir -p "$T/elsewhere"
printf '#!/bin/sh\ntouch "%s/ran"\n' "$T/elsewhere" > "$T/elsewhere/bootstrap.sh"
mv "$WS/handbook/bootstrap.sh" "$T/real-bootstrap.sh"
ln -s "$T/elsewhere/bootstrap.sh" "$WS/handbook/bootstrap.sh"
handbook_ok_line=$(sed -n '/^handbook_checkout_ok()/,/^}/p' "$ROOT/install.sh")
eval "$handbook_ok_line"
if handbook_checkout_ok "$WS/handbook"; then fail "a linked bootstrap.sh was accepted"; fi
rm "$WS/handbook/bootstrap.sh"; mv "$T/real-bootstrap.sh" "$WS/handbook/bootstrap.sh"

# A workspace path with an apostrophe reaches bootstrap intact.
make_origin "$T/origin.git" "$CURRENT"
WS2="$T/O'Brien/Ospina"
OSPINA_WORKSPACE="$WS2" run_installer
[ "$rc" -eq 0 ] || fail "a workspace with an apostrophe exited $rc"
[ -f "$WS2/handbook/args.txt" ] || fail "bootstrap did not run in a workspace with an apostrophe"

# Found again through the profile line bootstrap wrote, quoting and all.
printf "export OSPINA_HANDBOOK='%s'\n" "$(printf '%s' "$WS2/handbook" | sed "s/'/'\\\\''/g")" > "$T/home/.zshrc"
rm -f "$WS2/handbook/args.txt"
run_installer
[ "$rc" -eq 0 ] || fail "re-run of a workspace with an apostrophe exited $rc"
grep -Fq "found your existing setup at $WS2" "$T/out" || fail "a profile path with an apostrophe was not found"
[ "$(cat "$WS2/handbook/args.txt")" = "--no-login --update" ] || fail "the apostrophe workspace was not updated"

# A handbook folder that is a link could point at any checkout: not a setup.
mkdir -p "$T/linked"
ln -s "$WS2/handbook" "$T/linked/handbook"
if handbook_checkout_ok "$T/linked/handbook"; then fail "a linked handbook folder was accepted"; fi
if handbook_checkout_ok "$T/linked/handbook/"; then fail "a trailing slash let a linked handbook folder through"; fi

# A recorded path that reaches the handbook through a link and .. is taken at
# its physical location, so the checkout validated is the checkout that runs.
mkdir -p "$T/real/child" "$T/other"
git clone -q "$T/origin.git" "$T/real/handbook"
git -C "$T/real/handbook" remote set-url origin https://github.com/ospina-company/handbook.git
git -C "$T/real/handbook" config url."$T/origin.git".insteadOf https://github.com/ospina-company/handbook.git
mkdir -p "$T/other/handbook"
printf '#!/bin/sh\ntouch "%s/untrusted-ran"\n' "$T" > "$T/other/handbook/bootstrap.sh"
ln -s "$T/real/child" "$T/other/jump"
rm -f "$T/home/.zshrc"
printf '%s\n' "$T/other/jump/../handbook" > "$T/home/.config/ospina-handbook/bootstrap-state/handbook-dir"
run_installer
[ ! -e "$T/untrusted-ran" ] || fail "a link and .. ran a checkout other than the validated one"
[ -f "$T/real/handbook/args.txt" ] || fail "the validated checkout did not run: $(cat "$T/out")"
[ "$(cat "$T/real/handbook/args.txt")" = "--no-login --update" ] || fail "the validated checkout was not updated"
rm "$T/home/.config/ospina-handbook/bootstrap-state/handbook-dir"

echo "install.sh re-runs update an existing setup without prompting"
