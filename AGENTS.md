# Repository Guidelines

## Project Structure & Module Organization

This is an Elixir umbrella project. The root `mix.exs` owns shared project
configuration and declares `apps_path: "apps"`; individual OTP applications
belong in `apps/<app_name>/`. Keep each app self-contained, with implementation
code in `apps/<app_name>/lib/` and tests in `apps/<app_name>/test/`. Shared
runtime configuration belongs in `config/config.exs`. The repository currently
contains only the umbrella skeleton, so create application and test directories
as features are added.

Create every new umbrella application from the repository root with Mix, for
example `mix new apps/command_control_module --sup` or
`mix new apps/hypervisor_scheduler_module --sup`. Use `--sup` for OTP
applications that own processes; keep the generated `mix.exs` inside the app
and then run root-level `mix compile` to confirm umbrella discovery.

## Build, Test, and Development Commands

- `mix deps.get` fetches root-level dependencies.
- `mix compile` compiles all umbrella applications.
- `mix test` runs the test suites for the umbrella applications once tests
  exist.
- `mix format` formats `mix.exs`, `config/*.exs`, and files in `apps/*` using
  `.formatter.exs`.
- `mix format --check-formatted` verifies formatting without changing files;
  run it before submitting changes.

Use the pinned runtime versions in `.tool-versions` (Erlang 29.1.1 and Elixir
1.20.4-otp-29) to avoid version-specific formatting or compilation differences.

## Coding Style & Naming Conventions

Write idiomatic Elixir and let `mix format` determine indentation and layout;
do not hand-align code against formatter output. Use `snake_case` for files,
functions, variables, atoms, and application directory names. Use PascalCase
modules under an application namespace, for example
`Libvirtex.Connection` in `apps/libvirtex/lib/libvirtex/connection.ex`.
Keep public functions documented when their behavior is not obvious.

## Testing Guidelines

Add ExUnit tests alongside every new application under
`apps/<app_name>/test/`, with files ending in `_test.exs`. Name test modules
after the unit under test, such as `Libvirtex.ConnectionTest`. Cover normal
behavior, validation or error paths, and regressions. Run `mix test` and the
format check locally before opening a pull request. No coverage threshold is
currently configured.

## Commit & Pull Request Guidelines

History currently uses short, imperative subjects (for example,
`Init project skeleton`). Follow that style: keep the subject focused and add a
body when context or trade-offs matter. Pull requests should describe the
change, list validation commands run, link relevant issues, and include sample
output or screenshots when behavior is user-visible. Keep unrelated edits out
of the same change.
