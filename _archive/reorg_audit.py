"""
reorg_audit.py
---------------
Reconciles the two local project folders against reality:

    MLB_ANALYSIS_DIR  -> mlb-market-engine (app code, Docker, CI - this
                          repo is healthy and correctly pushed already)
    AWS_DIR           -> mlb-engine-aws    (Terraform/infra - currently
                          NOT pushed to GitHub at all; also has dead
                          duplicate Dockerfile/entrypoint.sh/Entrypoint.bash
                          files that don't belong here)

What this does, by default (no files touched, report only):
    1. Lists every file in AWS_DIR that has never been committed to
       origin/main - i.e. everything currently at risk of being lost if
       this machine dies.
    2. Flags files in AWS_DIR that are dead duplicates of files that
       properly live in MLB_ANALYSIS_DIR (Dockerfile, entrypoint.sh,
       Entrypoint.bash) - these get moved to an _archive subfolder, never
       deleted outright.
    3. Flags files that should never be committed to a Terraform repo at
       all (DB dumps, logs, anything that looks like it might hold
       secrets) and writes a proper .gitignore for AWS_DIR.
    4. Diffs entrypoint.sh between the two folders so you can see exactly
       what changed in the copy that never made it anywhere.

Run:
    python reorg_audit.py                  # report only, nothing touched
    python reorg_audit.py --apply          # actually move dead files to
                                            # _archive/ and write .gitignore

Nothing here runs git commands for you - after --apply, you still review
and run `git add` / `git commit` / `git push` yourself in AWS_DIR. This
script only cleans up the filesystem and tells you what to do next.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

# ---------------------------------------------------------------------------
# Adjust these two paths if your folders are named/located differently.
# ---------------------------------------------------------------------------
MLB_ANALYSIS_DIR = Path(r"C:\Users\W\PyCharmMiscProject\MLB_Analysis")
AWS_DIR = Path(r"C:\Users\W\PyCharmMiscProject\projects\mlb-engine-aws")

# Files in AWS_DIR that are dead duplicates - the real versions live in
# MLB_ANALYSIS_DIR and feed the actual Docker build. These get archived,
# not deleted, in case anything unique got typed into them.
DEAD_DUPLICATES = ["Dockerfile", "entrypoint.sh", "Entrypoint.bash"]

# Files that should never be committed to the Terraform repo - either
# too large/binary for git, transient debug output, or a plausible home
# for secrets that shouldn't be published even to a private repo.
NEVER_COMMIT = [
    "mlb_engine_backup.dump",
    "logs.txt",
    "ssm-params.json",
    "*.tfstate",
    "*.tfstate.backup",
    "*.pem",
    "*.pfx",
    "terraform.tfvars",
]

GITIGNORE_CONTENT = """\
# Terraform working files - regenerated, never committed
.terraform/
*.tfstate
*.tfstate.backup
*.tfplan

# Secrets / sensitive local files - review before ever removing these lines
terraform.tfvars
*.pem
*.pfx
ssm-params.json

# Large / transient files that don't belong in git history
*.dump
logs.txt
"""


def run(cmd: list[str], cwd: Path) -> str:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return result.stdout.strip()


def files_never_pushed(repo_dir: Path) -> list[str]:
    """
    Compares the local working tree against origin/main. Returns files
    that exist locally but aren't in the last-fetched remote state -
    i.e. genuinely at risk if this machine is lost. Assumes `git fetch`
    has already been run recently (this script doesn't fetch for you,
    to avoid surprising network calls).
    """
    tracked_remote = set(
        run(["git", "ls-tree", "-r", "origin/main", "--name-only"], repo_dir).splitlines()
    )
    tracked_local = set(
        run(["git", "ls-files"], repo_dir).splitlines()
    )
    untracked_local = set(
        run(["git", "ls-files", "--others", "--exclude-standard"], repo_dir).splitlines()
    )
    all_local = tracked_local | untracked_local
    return sorted(all_local - tracked_remote)


def diff_entrypoint() -> None:
    a = MLB_ANALYSIS_DIR / "entrypoint.sh"
    b = AWS_DIR / "entrypoint.sh"
    if not a.exists() or not b.exists():
        print("  (one of the two entrypoint.sh files doesn't exist - skipping diff)")
        return
    a_text = a.read_text(errors="replace").splitlines()
    b_text = b.read_text(errors="replace").splitlines()
    if a_text == b_text:
        print("  Identical - no divergence.")
        return
    print(f"  DIFFERENT. {a} has {len(a_text)} lines, {b} has {len(b_text)} lines.")
    print("  The one in MLB_Analysis is the one that actually matters (it's what")
    print("  build-and-push.yml builds from). Confirm it has the streamlit_app case")
    print("  before considering this resolved.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true",
                         help="Actually move dead duplicates to _archive/ and write .gitignore. "
                              "Without this flag, only prints the plan.")
    args = parser.parse_args()

    print("=" * 70)
    print("1. Files in mlb-engine-aws that have NEVER been pushed to GitHub")
    print("=" * 70)
    at_risk = files_never_pushed(AWS_DIR)
    if not at_risk:
        print("  None - everything's pushed. (Unexpected given what we found - "
              "did you run `git fetch origin` recently in this folder?)")
    else:
        for f in at_risk:
            flag = "  <-- DEAD DUPLICATE, will be archived" if f in DEAD_DUPLICATES else ""
            print(f"  {f}{flag}")
    print()

    print("=" * 70)
    print("2. entrypoint.sh divergence check")
    print("=" * 70)
    diff_entrypoint()
    print()

    print("=" * 70)
    print("3. Files that should never be committed (recommend .gitignore)")
    print("=" * 70)
    for pattern in NEVER_COMMIT:
        matches = list(AWS_DIR.glob(pattern))
        for m in matches:
            size_mb = m.stat().st_size / (1024 * 1024)
            print(f"  {m.name}  ({size_mb:.1f} MB)")
    print()

    if not args.apply:
        print("Dry run only - nothing was moved or written.")
        print("Re-run with --apply to archive dead duplicates and write .gitignore.")
        return

    print("=" * 70)
    print("Applying changes...")
    print("=" * 70)

    archive_dir = AWS_DIR / "_archive"
    archive_dir.mkdir(exist_ok=True)
    for name in DEAD_DUPLICATES:
        src = AWS_DIR / name
        if src.exists():
            dest = archive_dir / name
            shutil.move(str(src), str(dest))
            print(f"  Archived {name} -> _archive/{name}")

    gitignore_path = AWS_DIR / ".gitignore"
    existing = gitignore_path.read_text() if gitignore_path.exists() else ""
    if GITIGNORE_CONTENT.strip() not in existing:
        with open(gitignore_path, "a") as f:
            if existing and not existing.endswith("\n"):
                f.write("\n")
            f.write("\n" + GITIGNORE_CONTENT)
        print(f"  Updated {gitignore_path}")
    else:
        print("  .gitignore already up to date.")

    print()
    print("Next steps (manual - review before running):")
    print("  cd", AWS_DIR)
    print("  git add .")
    print("  git status   <- REVIEW this carefully before committing")
    print('  git commit -m "Add Terraform infrastructure source (first real commit)"')
    print("  git push origin main")


if __name__ == "__main__":
    main()