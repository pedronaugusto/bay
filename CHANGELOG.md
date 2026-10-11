# Changelog

## [Unreleased]

### Added

- The development build has the package's own dependencies as well as its dev dependencies, as a crate's tests have its dependencies in Cargo: a dependency the package ships and develops with is listed once. A name pinned differently in both lists is refused.
- `.dev_dependencies` beside `.dependencies`, and the development build that runs a package's `dev` function with them.
- `bay new`, `init`, `add`, `remove`, `update`, `list`, `fetch`, and `bay <step>`.
- `bay dev`: the development build, as given; bay sets `BAY` to itself for what it runs.
- `bay install`, `install --list`, `install --update` and `uninstall`: global installs, as `cargo install` makes them.
