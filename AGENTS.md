# Agent instructions: ospina-company/.github

This repository is **public**. Anyone can read everything pushed to it: files,
commit messages, branch names, pull request titles and descriptions, review
replies and comments. It serves the one-command installers
(`install.ps1`, `install.sh`) and the organization profile
(`profile/README.md`).

## Never name anything private here

Do not name a client, a prospect, a partner deal, a private repository, a
person outside Ospina, or a machine. Describe them instead: "several client
repositories", "a partner's Windows laptop", "the owner's workstation".

This applies to commit messages and pull request text as much as to files.
Before you push or open a pull request, reread every commit message and the
PR description for names. Fix a slip before it is pushed: rewriting a commit
message after the fact does not remove it from GitHub. The old commit stays
reachable through pull request references and the edit history until GitHub
Support purges it, which takes deleting the affected pull requests.

The same rule is in the handbook's `conventions/projects-root.md`, and it holds
for any other repository that is public. Check with
`gh repo view --json visibility`.

## Working here

- The installers hand off to the handbook's `bootstrap.sh`. Keep logic that
  installs or configures tools there, not here.
- Pull requests follow the company review policy. See
  `docs/agents/coderabbit-pr-review-loop.md`.
- The installer tests are `.github/tests/` and run in
  `.github/workflows/installer-smoke.yml`.
- `profile/README.md` is outward-facing copy. House prose rules apply.
