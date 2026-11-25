# GitSession — Ephemeral & Protected Git Workspace Manager

**GitSession** is a lightweight, portable Windows CMD & PowerShell tool for managing temporary ("ephemeral") GitHub clones alongside long-lived ("protected") local repositories from one clean terminal dashboard.

Designed for shared workstations, temporary work environments, and clean developer workflows: clone private or public repos using an **isolated GitHub CLI session**, sync or inspect local repos, push unsaved work, and securely wipe ephemeral clones on logout—without touching protected local repositories or system GitHub credentials.

---

## Features

- **Portable Single-Click Launcher (`GitSession.bat`)**: Double-click in Windows Explorer or run directly from Command Prompt / Windows Terminal. No Python, Node.js, or GUI runtime required.
- **Automatic Dependency Installation**: Checks for **Git CLI** (`git`) and **GitHub CLI** (`gh`) on startup and offers automated installation via `winget` if missing.
- **Complete Authentication Isolation**: Configures a private `GH_CONFIG_DIR` (`%LOCALAPPDATA%\GitSession\gh`) with file-based `--insecure-storage`, keeping your primary Windows Credential Manager and global `gh` CLI login untouched.
- **Dual-Tier Repository Safety (`Ephemeral` vs `Protected`)**:
  - **Ephemeral (`[EPHEM]`)**: Cloned inside GitSession. Audited for uncommitted/unpushed changes and safely removed on `[8] Logout & Clean Workspace`.
  - **Protected (`[PROT]`)**: Pre-existing or manually cloned repositories automatically discovered inside your workspace. Fully controllable inside GitSession while strictly excluded from Logout cleanup unless explicitly toggled.
- **Auto-Discovery & Remote Normalization**: Scans your workspace for `.git` directories, ignores tool/utility folders (`GitSession`, `node_modules`, `.vs`, `.venv`), and normalizes HTTPS/SSH remotes into canonical `owner/repo` slugs—even when the local folder name differs from the GitHub repository name.
- **Workspace Sync & Update Center (`[2]`)**:
  - Compact Sync Matrix showing folder, branch, ahead/behind status (`↑` / `↓` / `≡`), working tree status, and tracking mode.
  - Supports **Fetch All** (`git fetch --all --prune`), **Full Sync**, **Smart Pull** (`ff-only` / `merge` / `rebase` with interactive stash-and-rebase prompt on dirty repos), and **Batch Push**.
- **Interactive Local Repo Manager (`[3]`)**:
  - Per-repo Inspector with inline `git status -s` & `git diff --stat`, branch switcher/creator (local + `origin` tracking), quick commit & push (including inline Git author setup on fresh machines), shallow-clone unshallow, Explorer/Terminal/IDE integration (`code`, `cursor`, `windsurf`, `wt`, `pwsh`), and `Protected` $\leftrightarrow$ `Ephemeral` toggles.
- **Resilient Repository Browser & Clone (`[1]`)**:
  - Paginated `gh api --paginate` listing supporting accounts with `>100` accessible repositories (personal, private, forks, collaborator, and organization repos).
  - Multi-selection (`1`, `1,3`, `1-4`), direct GitHub URL or `owner/repo` cloning, live `/query` search, sorting (`[S]`), fork collision scoping (`<owner>_<repo>`), and 500 MB HTTPS buffer resilience against `curl 56` connection resets.
- **Configurable Settings (`[7]`) & Portable Mode**:
  - Customize Workspace path, auto-scan depth, default adopted mode, clone mode (`full` vs `shallow`), HTTP buffer size, pull strategy, page size, editor/terminal preferences, ignored folders, and optional portable `settings.json` mode.
- **Safe Cleanup Guardrails**: Validates strict workspace containment before deleting any directory, handles directory junctions/symlinks safely without recursing outside, and detects locked files with `[R] Retry / [S] Skip / [C] Cancel`.

---

## Dashboard Preview

```text
============================================
                 GITSESSION
       Ephemeral Git Workspace Manager
============================================

 Status     : Authenticated
 Account    : @username
 Workspace  : GitSession-Workspace
 Local Repos: 3 (1 Ephemeral, 2 Protected)

 [1] Browse & Clone Repository
 [2] Sync & Pull Workspace
 [3] Local Repositories & Repo Actions
 [4] Open Workspace in Explorer
 [5] Push Local Changes
 [6] Remove Local Repository
 [7] Settings & Preferences
 [8] Logout & Clean Workspace
 [0] Exit

 Select an option [0-8]:
```

---

## Quick Start

### 1. Download or Clone
Clone this repository or download the latest release folder onto your Windows PC:
```cmd
git clone https://github.com/vasilytoosilly/GitSession.git
cd GitSession
```

### 2. Launch
- **Double-click** `GitSession.bat` in File Explorer, **or**
- Run from Command Prompt / Windows Terminal:
  ```cmd
  GitSession.bat
  ```

On first run, missing `git` or `gh` tools trigger a `winget` install prompt. By default, GitSession initializes your workspace at `%USERPROFILE%\GitSession-Workspace` (customizable anytime via `[7] Settings`).

You can also override the workspace on launch:
```cmd
GitSession.bat -Workspace "D:\Work\TempRepos"
```

---

## Menu & Workflow Reference

| Option | Action | Description |
|---|---|---|
| **[1]** | **Browse & Clone Repository** | Lists all accessible GitHub repos (`>100` supported via pagination). Supports `1`, `1,3`, `1-4`, exact names, direct GitHub URLs, `/query` search, `[S]` sort, `[N]/[P]` pages, and `[R]` refresh. |
| **[2]** | **Sync & Pull Workspace** | Scans workspace for local `.git` repos, displays Ahead/Behind & dirty status matrix, and runs `[F]` Fetch All, `[A]` Full Sync, `[P]` Pull Behind, `[U]` Push Ahead/Dirty, or `[D]` Re-scan. |
| **[3]** | **Local Repositories Manager** | Lists all Ephemeral and Protected repositories. Select `[1..N]` to open the **Repo Inspector** (Pull, Fetch, Commit & Push, Diff/Log, Branch Switcher, Open Terminal/Editor/Explorer/GitHub, Mode Toggle, Unshallow, Remove). |
| **[4]** | **Open Workspace in Explorer** | Opens the active workspace root in Windows File Explorer. |
| **[5]** | **Push Local Changes** | Scans for uncommitted changes or unpushed commits across workspace repos, offers inline staging/commit (with first-time author config if unset), and pushes with automatic upstream setup. |
| **[6]** | **Remove Local Repository** | Safely deletes a single local repo from disk (requiring typed confirmation for dirty or Protected repositories). |
| **[7]** | **Settings & Preferences** | Configure workspace path, discovery rules, clone/pull defaults, editor/terminal integration, ignored folders, and `[P]` Portable `settings.json` toggle. |
| **[8]** | **Logout & Clean Workspace** | Audits **Ephemeral** repos for unsaved/unpushed work (`[P]ush`, `[C]ancel`, `[F]orce discard`), safely removes ephemeral directories only, preserves all **Protected** repos, and clears isolated session credentials. |
| **[0]** | **Exit** | Exits cleanly while keeping your active session and local clones intact. |

---

## Project Structure

```text
GitSession/
├── GitSession.bat    # Windows Batch entry point & Winget dependency manager
├── GitSession.ps1    # Core interactive engine (UI, Sync, Discovery, Cleanup)
├── .gitignore        # Excludes portable user config & OS metadata
├── LICENSE           # MIT License
└── README.md         # Documentation
```

User manifest (`manifest.json`), isolated GitHub CLI credentials (`gh/`), and settings (`settings.json`) are stored in `%LOCALAPPDATA%\GitSession\` unless Portable Mode is enabled in Settings.

---

## Security & Safety Design

1. **Zero Global Credential Overwrite**: Uses `%LOCALAPPDATA%\GitSession\gh` as `GH_CONFIG_DIR` with `--insecure-storage`, and clears only isolated session files (`hosts.yml`, `state.yml`) on logout so Windows Credential Manager keys remain intact.
2. **Pre-Existing Repo Protection**: Discovered `.git` directories outside session clones default to `Protected` (`persistent`) and are excluded from logout deletion.
3. **Strict Path Containment**: `Remove-SafeDirectory` verifies every deletion path resolves strictly inside the workspace root and refuses root drives, system directories, or GitSession's own directory.
4. **Junction & Reparse Point Safety**: Unlinks Windows junctions/symbolic links without recursing into external targets.
5. **Locked File Reporting**: If files are held open by an IDE, build server, or terminal, cleanup aborts cleanly, lists affected paths, and offers `[R] Retry`, `[S] Skip`, or `[C] Cancel`.

---

## Requirements

- **OS**: Windows 10 or Windows 11
- **PowerShell**: Windows PowerShell 5.1 (built-in) or PowerShell 7+
- **CLI Tools**: Git (`2.20+`) and GitHub CLI (`gh 2.0+`), auto-installable via `winget`

---

## License

Released under the [MIT License](LICENSE).
