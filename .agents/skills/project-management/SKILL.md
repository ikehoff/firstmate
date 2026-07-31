---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
Cloning or registering a project is add intake and uses the same trigger.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Before adding, cloning, creating, or registering any project in the main home, inspect the authoritative `data/secondmates.md` routing table and judge every existing natural-language `scope:` against the proposed project or domain.
Apply `AGENTS.md` section 7's authoritative secondmate routing rules; if an existing scope owns that domain, route the new-project operation or work there instead of creating or registering a duplicate main-home clone.
Absence from the main `data/projects.md` registry is never evidence that no second mate owns the domain.
If the owning second mate cannot accept the route, report that concrete blocker or obtain an explicit captain redirection rather than silently duplicating the project in the main home.

Resolve the project name, destination, delivery mode, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

Choose the delivery mode when adding or creating the project:

- `no-mistakes` runs the full validation pipeline before a PR and is the default when the captain does not specify a mode.
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.

The optional `+yolo` posture changes routine approval authority but does not change the delivery mode.
Default it off, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the complete authority boundary and exceptions when it is on.

## Add or clone an existing project

Confirm the source URL, local project name, delivery mode, and autonomy posture.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.

Clone with `git clone <url> projects/<name>`, which honors the destination, and confirm the repository actually landed there before adding the registry entry or initializing.
Never clone with `gh-axi`: its `repo clone <repo>` takes no destination argument, so a second positional is silently discarded and the repository lands in the current working directory under its own remote name, reported as `clone: ok` with exit status 0 (verified 2026-07-31 against gh-axi 0.1.28).
Because that misplacement is reported as success rather than as an error, checking the command's exit status does not detect it and only inspecting the intended destination does.
`gh-axi` remains the tool for the GitHub API operations it owns, such as creating a remote repository.
A `no-mistakes` project must have an `origin` remote and must complete the initialization procedure below.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery mode, defaulting visibility to private and delivery mode to `no-mistakes`, then obtain the captain's explicit consent for those values.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally under the clone rule above, add the registry entry, and initialize it according to its delivery mode.
The `--clone` flag of `gh-axi repo create` accepts no destination either, so it cannot place the clone at `projects/<name>`; create the remote and clone it as two separate steps.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

A freshly created repository has no commits, and no worktree can be based on an unborn branch, so `bin/fm-spawn.sh` refuses to dispatch into it and names the missing initial commit.
Registering such a project is correct and the registry entry should record that it is empty; the project simply cannot receive work until an initial commit lands on its default branch.
Firstmate does not create that commit itself, so raise it with the captain as the concrete blocker before promising a first task.

## Initialize

Run no-mistakes initialization only for `no-mistakes` projects:

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
