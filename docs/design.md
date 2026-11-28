# Architecture

bay is a package manager on top of Zig's. Zig fetches, hashes and builds; bay decides what to fetch and writes the
graph Zig builds. Every library stays plain Zig: `zig build` works without bay, from each manifest's exact pins. The
README says how to use it; this page holds how it works and why. Change it with the code.

Its models: Go modules (selection, workspaces, `replace`, the toolchain line), Cargo (commands, dev-dependencies,
install, tree), Bazel's bzlmod (one version by default), PubGrub (say why a graph is refused).

## Dev dependencies

`.dev_dependencies` sits beside `.dependencies`. Zig ignores the field, so no consumer sees it and nothing in it can
form a cycle. `build()` is what ships; `pub fn dev(b, tools)` is development. bay writes the development root under
`.zig-cache/bay`: it depends on the package, its dependencies and its dev dependencies, and calls `dev` with a `tools`
type whose declarations are the dev dependencies' build scripts. A dependency's dev dependencies are never part of a
graph.

## Selection

Minimal Version Selection, as Go first designed it. A pin is a minimum: for each package (name and fingerprint) the
selected revision is the highest `.version` that any revision the graph reaches pins. Every reached revision is read
and its pins followed, so the answer does not depend on order or depth and selections only rise. (A pruned variant
that counts only selected revisions' pins either depends on depth or can oscillate; Go's pruning rests on go.mod
listing every module, which a Zig manifest does not.) The cost is reading every revision pinned anywhere, until tidy
moves old pins past them.

- **Commit pins are ordered by history, not version.** Between releases many commits carry the version their manifest
  last took, so a version names one content only at a release. A pin is a release when its `?ref=` is the tag of its
  manifest's version (or it names no commit, as an archive). When any pin of a package is a commit pin, bay selects
  the pinned commit that every other pinned commit (a release counting as its tag's commit) is an ancestor of. Commits
  that diverge are refused, never one picked. History is kept under bay's data directory as commit objects only
  (`--filter=tree:0`), each fetched once from its pin's repository; a graph of releases fetches nothing.
- **Releases pin releases.** `bay release` refuses a pin at no release, because a consumer building with plain
  `zig build` never runs this selection and takes each manifest's pins as written.
- **The package under development always wins** over any revision of itself (Go's main module), so a dev tool that
  depends on it gets the working tree, not a second copy.
- **One version, one content.** Two revisions with one `.version` and different contents are refused, unless the
  root's own pins or overrides decide.
- **Incompatible versions** (another major; below 1.0, another minor) are refused unless the root lets named ones
  coexist (`.coexist`).
- **Every refusal names its chains**: for each pin it names, the shortest chain of pins from a main module that
  reaches it ("reached by app 0.1.0 (at <dir>) → glint <commit> → …"), a dev pin followed only from a main module. A
  refusal whose pin no one can find is one no one can act on.
- Lazy pins take part like any other; bay fetches what it must read.

## Materialization: one hash per package

Zig follows exact pins, so bay hands Zig a graph in which each package appears once.

- The root's own pins are raised to the selection in its `build.zig.zon`, as Go writes go.mod, so plain `zig build`
  uses the same direct versions. Commands that change the graph (`add`, `remove`, `update`, `tidy`) write it; builds
  only check, and refuse with the command to run.
- Every package appears under exactly one hash: the selected revision's, or for a main module (the package under
  development, a workspace member, an override path) the hash its pins name. Where the content differs from that hash
  a fork supplies it: a main module's directory, or a selected revision whose own pins differ, copied with only its
  manifest's pins rewritten. Forks live under `.zig-cache/bay/forks` and reach Zig as `--fork=<dir>`, matched by name
  and fingerprint; a fork stands for exactly one hash and pins only hashes, since Zig refuses a fetched package a path
  outside itself. A fork standing for two revisions would put one build.zig in two modules, which the one-hash rule
  rules out.
- Refused, since Zig cannot build them as one graph: a package that is a directory in one place and pinned
  elsewhere (`.overrides` makes them one), and a `.coexist` line that would need a fork (a fork applies to every line).
- Only Zig unpacks packages, into the project's `zig-pkg`, which both builds share; bay's own reading copies follow
  Zig's rule for executable bits, so a fork is what Zig would unpack.

## Workspaces and overrides

- `bay.work` (ZON) lists local package directories developed together, as `go.work`. Every member is a main module: a
  pin to a member resolves to its directory. It applies only to the packages it lists: a package below it that is
  neither a listed directory nor a checkout of a member (same name and fingerprint) builds with its own pins alone.
- `.overrides` in the root manifest replaces a package for the whole graph with another source (a fork, a path), as
  Go's `replace` and Cargo's `[patch]`; it applies only when its package is the root.
- `bay tidy` writes only its own package's manifest; `bay --workspace tidy` tidies every member. A member whose pins
  are behind the selection is built from a copy of its tree with only those pins rewritten, so no build needs another
  member's manifest changed. In a workspace, tidy pins each member a package depends on at its release (its own
  `.version` tagged on its remote); a member with unreleased work keeps its pin.
- `bay --workspace [--jobs n] <command>` runs the command in every member, a member's normal dependencies first and
  independent members at once; a failure skips the members that depend on it.

## Toolchain and fetching

- `.zig_version` (default `.minimum_zig_version`) names the exact Zig, since pre-1.0 releases break. bay runs that
  Zig, downloaded from ziglang.org with its minisign signature checked, kept under bay's data directory; `ZIG` names one
  by hand. CI installs nothing but bay.
- `git+ssh://` and `git+file://` are fetched with the system's git (the person's keys and agent): the commit's tree is
  written out and hashed by `zig fetch <dir>`, which gives the hash Zig gives the same commit over https and keeps it
  in Zig's cache, so Zig builds the pin and never fetches it. Tags, `update` and `outdated` read such remotes with
  `git ls-remote`.
- `bay update` follows a recorded ref: a branch to its head, a release tag to the newest release on its line; a new
  line is `bay add` at its tag.

## Seeing and checking

`bay tree` (`--why`, `--duplicates`); `--locked` refuses to change a manifest (reading remotes is allowed); `bay
outdated` reads newer tags; `bay vendor` writes the whole graph into `zig-pkg`, which Zig reads before any network;
`bay licenses [--dev]` lists the license each package's files state (an SPDX line, else the wording). `.retracted` in
a package's newest release names its bad versions, read as Go reads `retract`: `outdated` reports one in use and
`update` never moves to one; builds do not consult the network. With no advisory database for Zig, `bay audit` reads
each selected package's published security advisories from its repository's forge, matches them against the
version selected, adds any retracted version, and exits non-zero on a finding so CI can gate on it.

## Releasing: `bay release`

Choosing a version, writing the changelog, tagging and re-pinning dependents is the package manager's job; the gate
(preflight) only verifies. So one command releases, and the commit tagged is the commit the gate saw whole. `bay
release` is the one writer of a `vX.Y.Z` tag, of its GitHub Release and of a dependent's pin onto a release; everything
else reads them, and `bay audit releases` checks that it was so.

- **The CHANGELOG is the input.** Every user-visible change adds a `- ` entry under `## [Unreleased]`, in one of
  `### Breaking`, `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`. Each repository's `.gitattributes`
  gives CHANGELOG.md git's `union` merge driver, so concurrent branches adding lines never conflict; bay orders the
  section at release. One reader of the format, bay's `changelog` module (std only), which preflight imports, so the
  checker reads what the writer writes.
- **The version** is the section's: Breaking and Removed are breaking (the minor below 1.0); from 1.0 Added and
  Deprecated move the minor; the rest the last number. An empty section releases nothing. preflight's gate checks the
  section against its API diff since the last tag, so a disagreement is a refusal, never a silent bump.
- **Steps.** Refuse a dirty tree, a branch behind its remote, a release to anything but the remote's default branch
  (releases are one line), a push URL that is not SSH, a version already tagged, or a pin at no release. Write
  `## [X.Y.Z] - date` and `.version`, commit `Release vX.Y.Z`: the version commit.
- **The proof: the full run of the head the tag names.** A package on github.com whose `ci.yml` (preflight's)
  dispatches a full tier (`full`, `release` before preflight 0.20.0, read from the generated workflow, never assumed)
  is proved there. Its version commit is configured and built here (`bay fetch`, then its `check` step, or its install
  step where neither build has one) and lands on the default branch as any change does: nothing on the Mac runs a full
  suite. The commit is pushed to `refs/heads/release/vX.Y.Z` as well, so a push to main meanwhile cannot move what is
  proved, and the tier is dispatched there through GitHub's API with the person's own login (`GITHUB_TOKEN`, else
  `gh auth token`; bay stores none) and waited on, each job said as it ends (`BAY_POLL_SECONDS` between looks, 30 by
  default). The run found is recorded in bay's data directory under its commit, so a stopped wait takes the same run
  up again. A batch's runs are paced to the account's runners (GitHub Free: 20 jobs at once, 5 on macOS, of which the batch takes 14, 3 on macOS, leaving the rest to landings; a job queued
  past its runner's wait is cancelled unrun): a run is dispatched only while the jobs its plan holds, read from the
  matrices `ci.yml` carries, fit beside the jobs the runs going still have queued or in progress, read from GitHub
  at each look (a run not yet shown, or with no job listed, holds its plan); one whose plan alone is larger starts
  when the batch holds no runner; and a job of the batch's own runs queued at two looks in a row holds back every
  dispatch until it starts, as the account's runners are shared with what the batch does not see. One batch at a time on the machine: the
  `release_queue` lock, waited on. A login is asked for before anything is made.
- **The tag goes on the proved head.** Green: an annotated tag on that very commit, its message the version and a
  `Proved-by:` line with the run's page, pushed atomically with the branch (already there) and read back with
  `git ls-remote`, and only then the local tag; the candidate is deleted. A GitHub Release follows, its notes the
  CHANGELOG section and the run, and for programs, binaries and `SHA256SUMS`. Red: the failing jobs named, the
  candidate deleted, the version commit left on main untagged. A package with no full tier on GitHub is gated here
  instead, through its own `gate` step (the preflight its manifest pins: run, never linked, which would make bay judge
  every package with its own preflight and close a ring), here and on each machine in `machines.zon` (a name, the
  command that runs bay there, a directory), sent as a git bundle, all at once, each line of output named; then landed
  and tagged.
- **Git is the record of an interrupted release.** A version commit that fails its build or gate resets the branch. A
  version the CHANGELOG releases and no tag names is a release under way, its version commit landed or not: the next
  run takes it up at HEAD, landing what is not landed, proving that head and tagging it, never cutting the version
  again; a fix lands on it with its line in the version's own section, and an entry under `[Unreleased]` meanwhile is
  refused. A release found on the remote is confirmed and tagged here. A commit checked green whose landing failed is
  recorded in bay's data directory and landed next time without a second check: only the same user can write the
  record, and that user can push with git anyway.
- **The train**, `bay --workspace release`: the family as one batch. Refused first: a member without
  `"policy": "family"` in its `ci/preflight.json` (the key preflight's configuration and build both read; bay never
  writes it), off its default branch, dirty or behind; then the family is built once in the workspace at the commits it
  releases (the dry run's plan: each member's release commit made in a copy, pinned as the train pins it, and built in the member's Zig cache; one built before at the same inputs, its tree, the trees of the members it builds with, its Zig and bay, is not built again, until a train releases every member). In dependency order each member is pinned at the version commits of the batch members it depends on, as
  their tags will pin them (`?ref=vX.Y.Z#<commit>`: Zig fetches the commit and never reads the ref, so the pin
  fetches before the tag exists and is byte for byte the tag's pin after), tidied to the releases there are (one
  `### Changed` line, "Pins x 1.2.0 and y 0.3.1.", for the versions that moved), and its version commit landed; a
  member whose only change is development pins is checked and pushed untagged. Then every landed head is proved at
  once, and each head is tagged as soon as its run is green and the batch members it pins are tagged, while the other runs go on, so its tag's pins name tags
  at exactly those commits. A failed member stops its dependents only; a red run leaves its dependents proved and
  untagged until its fix.
- **One package onto one release**, `bay pin <dependency> <version>`: pinned at the tag and tidied, the re-pin named
  and committed as the train does, then released when the section held entries before it; a re-pin alone is checked
  and pushed untagged, its entry waiting for the next release. The refusals of a release come first.
- **The audit**, `bay audit releases`: every `v*` tag of the package's repository on GitHub, from the first release
  proved there on, must be an annotated tag whose `Proved-by` run (or, for releases made before the proof, its
  `Gated-by` release tier run) is green on that very commit and its candidate ref, with a GitHub Release whose notes
  name the run. Each tag that falls short is named with what it lacks, and the run fails; the tags before that first
  release are named once, as history.
- `--dry-run` prints the version, the section and the plan, and writes nothing.

## Prebuilt pins

Runtimes and tools that ship only as archives Zig's fetch refuses are pinned as Zig itself is: by URL and digest,
checked against what the publisher signs.

- **One entry in `.dependencies` or `.dev_dependencies`**, with bay's fields beside Zig's: `.url =
  "bay+https://…"`, `.hash` (Zig's hash of the unpacked tree, checked at every build), `.sha256` and `.size` (the
  archive's bytes, checked before anything is unpacked; the download stops past `.size`), `.publisher` and
  `.license`. The build reaches it by name, `b.lazyDependency(...)`, with no bay code in `build.zig`; Zig ignores the
  unknown fields, so plain `zig build` and bay read one entry. Zig fetches no `bay+` scheme, so a plain build that
  needs the pin stops at its line and never runs without it. Plain `bay+http` is allowed only to a loopback address
  written as a number.
- **`.publisher` is required**, from a closed set bay checks: `.minisign` (key; the signature at URL + `.minisig`,
  its trusted comment naming the file), `.openpgp` (a key file the package ships; a v4 detached signature at URL +
  `.sig`, RSA PKCS#1 v1.5 or Ed25519 over SHA-256 or SHA-512; no keyring), `.nuget` (the SHA-512 `packageHash` from
  nuget.org's catalog, a document apart from the blob: nuget.org's word over TLS, so it catches a swapped mirror, not
  nuget.org itself; with `.root` and `.root_sha256` it also checks the author's signature, chained to that root,
  through cloak's `cloak-nuget-check`, built from the cloak bay pins, so bay carries no CMS or trust store), or
  `.none`, written by hand so the choice shows. A `.nuget` pin outside nuget.org is refused until a pin can name its
  feed's index.
- **OpenPGP is checked in bay; NuGet's author signature is not.** An `.openpgp` pin's check is one detached
  signature against the one key the pin names, through std's own RSA, Ed25519 and SHA-2 (SHA-1 only for the v4
  fingerprint), with no keyring and no trust store, so it stays in `openpgp.zig`. A NuGet author signature is CMS
  chained to a root through a certificate store, which is cloak's, so it goes to cloak's tool. That keeps cloak out of
  the toolchain's closure: bay does not depend on cloak, whose tool is built only for a `.nuget` pin that names a root.
- **One pin, one archive.** A runtime that needs three archives is three pins, and the consumer's build that knows
  the layout puts them together.
- **Formats are told by the bytes**, never the URL or Content-Type: zip (stored, deflate, zip64), and a tar alone or
  in gzip, xz or zstd. bzip2 and LZMA-alone are refused by name. A zstd frame is decoded at the window it declares,
  refused above 128 MiB (the reference decoder's default limit), with no override; xz's dictionary has the same bound.
- **The tree is the one Zig's fetch would make**, so a pin hashes alike everywhere: a single top directory stripped,
  empty directories dropped, executable bits from file headers. Every entry name is checked before anything is
  written (relative, no `..`, no drive or UNC prefix, no backslash, NUL, `:` or reserved name, no two names equal under
  case folding). A link inside the tree is kept as Zig keeps it, and refused by name on a host that cannot make links;
  a link out of the tree is refused. The unpack stops past the size the hash records.
- **Kept by digest** in `<data>/prebuilt/<sha256>`, written under a `.partial` name behind a lock; the tree goes into
  Zig's cache by `zig fetch <dir>`, so a cleared cache refills from the archive with no network.
- **Fetched only when a build needs it.** A non-lazy prebuilt is brought before `zig build`. For a lazy one Zig lacks,
  bay first runs the same build with `-l`, reads the `info: fetching lazy dependency <hash>` lines configure prints
  for what it needs, fetches those, then builds. The line is Zig's text, not an interface: if it changes the probe finds
  nothing and the build stops at the pin's line, never runs without it, and bay's test of the probe quotes the exact
  text on the Zig bay builds with. `bay fetch` brings every prebuilt; `bay vendor` includes their trees.
- A prebuilt has no manifest, so selection does not read it.

## Rules

- bay is a toolchain package: its runtime closure is std and the family's toolchain packages (aegis, ensign, airlock,
  hold, warp), never cloak or anything above them; what needs more (a CMS check) is a separate tool bay runs.
- bay writes only its own package's files, its `.zig-cache/bay`, Zig's cache and bay's data directory; everything in
  the data directory is a cache, safe to delete, except the record of a gated release waiting for its push.
