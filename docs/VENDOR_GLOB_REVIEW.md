# Vendored Rust glob re-exports

Run the focused checks from the repository root:

```sh
sh tests/run.sh vendor_glob_paths vendor_glob_gate
```

The [no-glob-reexport rule](../rules-examples/rust/no-glob-reexport.yml)
protects the API style of authored Rust. Upstream packages can deliberately
export glob APIs, so this rule now excludes paths containing an exact `vendor/`
directory component. The exclusion belongs to this one style rule. All other
rules, staged-file selection, default BLOCK severity and safety gates are kept.
The existing negative `files:` entries are unchanged; adding another negative
`files:` entry did not exclude vendor paths in the measured ast-grep 0.51.0 scan.
The working boundary uses ast-grep's `ignores:` field.

The [category 37 tests](../tests/37-vendor-glob-boundary.t.sh) generate their
fixtures outside the source tree. `t_case_vendor_glob_paths` exercises nine real
paths through this rule: three root/nested vendor paths must have no match; six
authored, sibling and vendor-lookalike paths must still match the same glob API.
`t_case_vendor_glob_gate` stages a vendor glob beside a named authored re-export
and runs the real default [QA gate](../hooks/common/qa_gate.sh). It then stages an
authored glob, requires a BLOCK naming this rule, repairs only the authored code,
and requires acceptance with the vendor bytes unchanged. These are real staged
and validated-cache controls, rather than checks of the YAML's spelling.

On Windows/Git Bash the author used Git Bash's POSIX tools first on PATH and its
`/tmp` directory for both runs; no gate setting, installed hook or live rule
cache was changed. With the rule from main `1c27ef6502d1ed06ec56dde82980dcd21bd89f09`,
the exact new tests reported **9 passed, 5 failed, 0 skipped**: the three vendor
paths and two legitimate composed-gate acceptances failed. Adding the vendor-only
`ignores:` entry makes those five expectations pass while retaining the authored
refusal controls: **14 passed, 0 failed, 0 skipped**. The wider focused regression
(`blockers rule_behaviour vendor_glob_paths vendor_glob_gate`) reported
**134 passed, 0 failed, 15 skipped**. The skips belong to existing missing-tool,
inert-rule and documented overmatching cases; neither new selector skipped.
ShellCheck at warning severity passed for the new fixture and changed runner.
The whole repository suite was not rerun by this author.
Reproduce red by using the original rule with the new tests,
then apply the rule change and repeat the same command for green.

The machine-local author evidence is held under
`C:/codedev/evidence/pcai-fleet-integration/r2/integration/gitguard-vendor/` as
`red.log` and `green.log`; these paths identify external receipts, not repository
inputs or portable execution prerequisites. The hash-bound
[review register](VENDOR_GLOB_REVIEW.json) records the two selectors and rule.
This is source qualification, not an installed-release or fleet rollout claim.
Independent agent `codex-root`, who wrote neither selector, read both selectors,
the rule, registration and documentation at the register's exact hashes and
recorded **keep**. Their own focused run passed **14/14 with no failures or
skips**; the register binds its external log hash. Read-only scans of the actual
PC-AI Candle 0.9.2, 0.10.2 and 0.11.0 `src/quantized/mod.rs` files additionally
found two baseline matches per version and zero with this candidate; each source
file's bytes remained unchanged. This corroborates the generated fixture without
making those external package files prerequisites for the portable tests.
The normal PR checks, independent approval and supported release/install process
still apply. See the [rule inventory](RULES.md) for the surrounding gate contract.
