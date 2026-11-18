#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
check="$repo_root/scripts/check-rust-formatting.bash"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-rust-formatting.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
cd "$test_root"

cat > 'wrapped flow.rs' << 'RUST'
fn flow() {
    let term = read();
    if ![
        "ignored",
        "skipped",
    ]
    .contains(&term)
    {
        emit(term);
    }

    self.seen.insert(event.id);
    if matches!(
        state,
        State::Ready(id) if id == event.id
    ) {
        self.emit(event.id);
    }

    let mut result = value.clone();
    if let Some(item) = items
        .iter()
        .find(|item| item.id == value.id)
    {
        result.name = item.name.clone();
    }

    let mut step = 0;
    loop {
        step += 1;
        if ready()
            && enabled()
        {
            break step;
        }
    }
}
RUST

cat > unrelated.rs << 'RUST'
fn flow() {
    let term = read();
    if ready()
        && allowed(term)
    {
        emit();
    }

    let term = read();
    if ready()
        && enabled()
    {
        emit();
        emit(term);
    }
}
RUST

cat > lib.rs << 'RUST'
#[macro_use]
mod macros;

pub mod public;

pub(crate) mod restricted;

mod private;

#[cfg(feature = "example")]
pub mod zeta;

#[cfg(any(test, feature = "example"))]
pub(crate) mod middle;

#[cfg(feature = "example")]
mod alpha;

#[cfg(all(feature = "example", test))]
pub mod tests;
RUST

cat > misplaced.rs << 'RUST'
#[cfg(feature = "example")]
mod alpha;

#[cfg(feature = "example")]
pub mod zeta;
#[cfg(feature = "example")]
pub mod beta;
RUST

cat > missing-section-gap.rs << 'RUST'
#[cfg(feature = "example")]
pub mod zeta;
#[cfg(feature = "example")]
pub(crate) mod beta;
RUST

cat > macro.rs << 'RUST'
/* Example: view! { /* a nested comment */ */
const EXAMPLE: &str = r#"view! {
mod zeta;
mod alpha;
"#;

fn view() {
    view! {
        let brace = '}';
        let text = " } ";
        if ready() {
            run();
        }
    };

    assert!(matches!(
        data,
        [State::Ready(id)]
            if enabled(id)
    ));

    prepare();
    if ready() {
        run();
    }
}
RUST

cat > struct-patterns.rs << 'RUST'
fn flow() {
    let value = read();
    if ready()
        && let Entry { id, .. } = entry
    {
        emit(value, id);
    }

    let value = read();
    while let Entry { id, .. } = next() {
        emit(value, id);
    }

    let value = read();
    for Entry { id, .. } in entries {
        emit(value, id);
    }

    let value = read();
    for entry in {
        entries()
    } {
        emit(value, entry);
    }

    let value = read();
    if count == 17 {
        emit(value);
    }

    let value = read();
    if code == b"ready" {
        emit(value);
    }

    let value = read();
    if unsafe {
        ready()
    } {
        emit(value);
    }

    let r#type = read();
    if ready() {
        emit(r#type);
    }
}
RUST

cat > exceptions.rs << 'RUST'
impl SomeVeryLongTraitName<LongTypeParameter>
    for AnotherVeryLongName
{
}

macro_rules! sample {
    () => {
        prepare();
        if ready() {
            run();
        }
    };
}

fn flow() {
    unsafe { // The first statement starts the block
        if ready() {
            run();
        }
    }

    prepare();
    #[cfg(any(
        feature = "a",
        feature = "b",
    ))]
    if ready() {
        run();
    }

    insert(
        key,
        tokio::spawn(run()),
    );

    let handle: JoinHandle<()> =
        tokio::task::spawn_blocking(move || compute_report(first_argument, second_argument));

    prepare();
    let example = stringify!(tokio::spawn(run()));

    match entry {
        State::Ready { id, .. }
            if enabled() => {
                run(id);
            }
        _ => (),
    }
}
RUST

cat > missing-separators.rs << 'RUST'
fn flow() {
    let flags = Flags::READ | Flags::WRITE;
    if ready() {
        emit();
    }

    let total: u64 = entries.iter().map(|entry| entry.size).sum();
    if ready() {
        emit();
    }

    let _ = prepare();
    if let (Some(_), true) = read() {
        emit();
    }

    prepare(); // See the setup (above)
    if ready() {
        emit();
    }

    let flags = Flags::READ
        | Flags::WRITE;
    if ready() {
        emit();
    }

    let b = read();
    if ready() {
        emit(b"ready");
        emit(b);
    }

    let config = load();
    tokio::spawn(run());
    apply(config);

    prepare();
    spawn(run());

    prepare();
    tokio::spawn::<_>(run());

    let b = read();
    if ready() {
        emit(b'\xFF');
        emit(b);
    }

    let r#gen = read();
    if ready() {
        emit(r#type);
        emit(r#gen);
    }

    let value = load();
    if ready() {
        emit(r#let);
        emit(value);
    }
}
RUST

cat > module-attributes.rs << 'RUST'
const EXAMPLE: &str = r#"
/*
#[cfg(
"#;

mod r#gen;

#[doc = concat!(
    "Public",
    " API",
)]
pub mod api;
RUST

run_check() {
  local expected_status="$1" expected_output="$2" stdout stderr status=0
  shift 2
  stdout=$(bash "$check" "$@" 2> check.stderr) || status=$?
  stderr=$(< check.stderr)
  if [[ "$status" -ne "$expected_status" || "$stderr" != "$expected_output" || -n "$stdout" ]]; then
    printf 'Expected status %s and stderr:\n%s\nGot status %s, stderr:\n%s\nAnd stdout:\n%s\n' \
      "$expected_status" "$expected_output" "$status" "$stderr" "$stdout" >&2
    exit 1
  fi
}

run_check 0 "" 'wrapped flow.rs' lib.rs struct-patterns.rs exceptions.rs

unrelated_output=$'unrelated.rs:3: Missing blank line above `if`\nunrelated.rs:10: Missing blank line above `if`'
run_check 1 "$unrelated_output" unrelated.rs

section_order='macro prelude, public, restricted, private, cfg-gated public, cfg-gated restricted, cfg-gated private, test-only'
printf -v misplaced_output '%s\n%s' \
  "misplaced.rs:5: Module \`zeta\` is in the wrong section; expected order: $section_order" \
  "misplaced.rs:7: Module \`beta\` is in the wrong section; expected order: $section_order"
misplaced_output+=$'\nmisplaced.rs:7: Module `beta` is not alphabetized in the cfg-gated public section'
run_check 1 "$misplaced_output" misplaced.rs
run_check 1 $'missing-section-gap.rs:4: Expected one blank line before cfg-gated restricted module `beta`' \
  missing-section-gap.rs
run_check 1 $'macro.rs:23: Missing blank line above `if`' macro.rs
printf -v missing_separators '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  $'missing-separators.rs:3: Missing blank line above `if`' \
  $'missing-separators.rs:8: Missing blank line above `if`' \
  $'missing-separators.rs:13: Missing blank line above `if`' \
  $'missing-separators.rs:18: Missing blank line above `if`' \
  $'missing-separators.rs:24: Missing blank line above `if`' \
  $'missing-separators.rs:29: Missing blank line above `if`' \
  $'missing-separators.rs:35: Missing blank line above `spawn`' \
  $'missing-separators.rs:39: Missing blank line above `spawn`' \
  $'missing-separators.rs:42: Missing blank line above `spawn`' \
  $'missing-separators.rs:45: Missing blank line above `if`' \
  $'missing-separators.rs:51: Missing blank line above `if`' \
  $'missing-separators.rs:57: Missing blank line above `if`'
run_check 1 "$missing_separators" missing-separators.rs
run_check 1 "module-attributes.rs:12: Module \`api\` is in the wrong section; expected order: $section_order" \
  module-attributes.rs

mkdir generated
cp unrelated.rs generated/bindings.rs
run_check 0 "" generated/bindings.rs
run_check 2 'Expected a readable Rust file: missing.rs' missing.rs
run_check 2 'Usage: check-rust-formatting.bash FILE.rs [FILE.rs ...]'

printf 'Rust formatting check tests passed\n'
