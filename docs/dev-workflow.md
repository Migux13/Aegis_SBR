# Local development workflow (Mercaius' machine)

> Not part of the addon. Describes how the two folders and the branches relate,
> so the live game folder is never left behind or half-updated.

## The two folders

| Folder | Role |
|---|---|
| `SichOctoWoW\Aegis_SBR` | dev / git working copy — **edit here** |
| `OctoWoW\Interface\AddOns\Aegis_SBR` | live game folder — **copy target only, never edited by hand** |

Verified changes are copied dev → live without asking. The live folder is not a
git repo; it is a plain mirror.

## The rule that makes this safe

**The dev folder stays on `local/integration` and never changes branch.**

That branch is local-only (never pushed) and holds `main` plus every feature
branch still in flight, merged in. So the dev working copy always contains
*everything current*, which is exactly what the live folder needs — a copy dev →
live is safe at any moment, no matter what state GitHub is in.

This exists because of a concrete failure mode: a git working copy only ever
holds ONE branch. Checking out a feature branch to commit it silently reverts
every file belonging to the other branches. Copy to live at that moment and the
game loses work that was already tested. `local/integration` removes the reason
to ever switch.

## Committing a feature without touching the dev folder

Work and commit on `local/integration` as usual. To turn a commit into a clean
PR branch off `main`, use a throwaway worktree instead of switching branch:

```bash
git worktree add ../_wt-feature -b feature/<name> main
git -C ../_wt-feature cherry-pick <sha>          # or several
git -C ../_wt-feature push -u origin feature/<name>
gh pr create --base main --head feature/<name> --title "..." --body "..."
git worktree remove ../_wt-feature
```

A worktree is a second checkout of the same repository in another directory. The
dev folder keeps `local/integration` the whole time, so live stays valid.

## After a PR is merged

```bash
git fetch origin
git checkout local/integration        # should already be there
git merge origin/main                 # pick up the merged work
git branch -d feature/<name>          # local branch, once merged
```

Then copy dev → live as usual. `local/integration` gradually flattens back onto
`main` as PRs land, so it never drifts into a fork.

## Identity

`user.name` / `user.email` are set **repo-locally** to `Mercaius
<taxor@gmx.de>`, matching every existing commit. No global git config was
touched.
