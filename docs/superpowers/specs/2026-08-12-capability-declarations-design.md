# Capability Declarations & Install-Time Consent — Design

**Status:** Proposed
**Relates to:** `koha-plugin-store-spec.md` §6 ("Levels model and submission workflow") and
`docs/superpowers/specs/2026-08-10-check-pipeline-design.md` (`DependencyAllowlist`, item 3 in its
required-checks list, and its "Deferred work" section, which already flagged the pattern-scan
approach as incomplete). This design proposes what replaces/extends `DependencyAllowlist` and adds
a new, related Koha-core piece; it does not touch any other check in that catalogue.

## Summary

`DependencyAllowlist` gates publishing on a plugin's code containing *no* occurrences of a fixed
set of risky patterns (`system()`, backticks/`qx//`, `exec()`, networking modules, filesystem
escapes). That's a blunt instrument: it can't distinguish a plugin that genuinely needs to shell
out (calling `sendmail`, ImageMagick, an external CLI) from one doing so maliciously, so any
legitimate use is simply unpublishable today. There's no path from "I need this" to "and here's
why" — the check only knows how to say no.

This design replaces the pure block-list with a **declare → verify → surface** model: plugin
authors declare risky capabilities and why they're needed; the store's check verifies the
declaration against actual code and fails only on *undeclared* usage; the declarations (plus a
statically-detectable list of which Koha plugin hooks the code implements) are surfaced on the
plugin's page and, eventually, in Koha's own install flow — so an admin installs with informed
consent rather than blind trust, the same shape app stores and browser extension stores converged
on for the same underlying problem.

## Motivating case study

`koha-plugin-crontab` (a real, already-published plugin bundling a vendored `Config::Crontab` CPAN
module) hit `DependencyAllowlist` failures across two release attempts, all without ever actually
needing to execute a shell command in its own code paths:

1. **A false positive from prose, not code.** `` `crontab -u $owner $tmpfile 2>&1` `` in
   `Config::Crontab`'s `write()` was real backtick execution — but a second hit came from a plain
   comment, `` # ...exactly as `add` does ``, where the backticks were markdown-style emphasis, not
   Perl syntax. The regex scan can't tell the difference; POD documentation using the classic
   ` ``word'' ` typographic-quote convention tripped the same rule eight more times, purely as
   prose.
2. **A false positive from an unrelated method sharing a name.** The vendored module has a boolean
   accessor named `system` (`$self->system(1)` — "is this a `/etc/crontab`-style entry"), nothing
   to do with Perl's `system()` builtin. `\bsystem\s*\(` cannot distinguish `system(...)` the
   builtin from `->system(...)` the method call; the only fix available was renaming the accessor
   itself — invasive, vendored-code surgery undertaken solely to satisfy the regex, not for any
   functional reason. A further false positive of the identical shape turned up in a plain
   `## system (user) syntax` comment.
3. **A real risk, but not on a path the plugin ever runs.** The genuine backtick shell-outs live in
   `write()`/`remove_tab()`'s fallback branches for writing to a *named user's* crontab via the
   `crontab` CLI. This plugin always calls `->file(...)` first, so it always takes the
   direct-file-write branch instead — the risky code is inert, vendored dead weight, not something
   this plugin's own logic relies on. It was still worth hardening (the owner value was interpolated
   unescaped into a shell string) but that fix was available specifically *because* the plugin
   didn't actually need the capability. A plugin that legitimately needs command execution has no
   equivalent escape hatch today.

Three failures, zero of which reflected an actual security-relevant choice made by the plugin
author, and the one case that *was* real would have been just as required-blocking if it had been
load-bearing. That's the gap this design closes.

## Proposed model

### 1. Declared capabilities (plugin-authored, needs a human-supplied reason)

New optional metadata block, alongside the existing `$metadata` hash `Task::ProcessPluginVersion`
already parses out of the plugin class file:

```perl
our $metadata = {
    ...
    capabilities => [
        {
            type   => 'system_call',       # matches a DependencyAllowlist pattern category
            target => 'crontab',            # free-text, shown to the admin verbatim
            reason => 'Writes the user crontab via the crontab(1) CLI when no explicit '
                    . 'crontab file path is configured.',
        },
    ],
};
```

`type` enumerates the same categories `DependencyAllowlist`'s `@RISKY_PATTERNS` already checks for
(`system_call`, `network`, `filesystem_escape`, ...) — not a new taxonomy, so the check's
cross-reference logic (below) stays a simple lookup rather than needing its own mapping table.

### 2. `DependencyAllowlist` becomes declare-aware

The check's pattern scan is unchanged (it's the correct, cheap way to *find* candidate risky
usage). What changes is the verdict:

- A risky-pattern hit with a matching `capabilities` entry (same `type`) → recorded, does **not**
  fail the check. The specific file/line and the declared reason both get stored on the
  `review_checks` row's `message`, so they're visible on the plugin page, not silently accepted.
- A risky-pattern hit with **no** matching declaration → fails exactly as today. This preserves
  `DependencyAllowlist` as a hard required-check gate for anything undeclared; declaring a
  capability is opt-in disclosure, not a way to silence the check.
- A declared capability that never matches any actual pattern hit → not a failure (metadata may
  legitimately describe conditional code paths a static scan won't always trip), but worth
  surfacing as an advisory note so stale declarations don't accumulate unchecked.

This directly resolves case 3 above (a real, declarable capability) without changing the outcome
for cases 1–2, which are pattern-scan false positives no declaration mechanism fixes — those still
need the regex itself to improve (comment/POD-aware scanning, an arrow-call exclusion for
`->system(`) as a separate, smaller fix to `DependencyAllowlist` itself, orthogonal to this design.

### 3. Hooks are enumerable, not declared

Unlike arbitrary risky calls, the set of method names Koha's plugin system recognizes as hooks
(`install`, `upgrade`, `intranet_catalog_biblio_enhancements`, `after_circ_action`, etc.) is a fixed,
finite vocabulary Koha core already defines. The store doesn't need the author to declare which
hooks a plugin uses — it can detect them directly by parsing `sub <hookname> {` against that known
list, the same static-introspection style `TranslatableTemplates`/`PluginTemplateWrapper` already
use for `.tt` scanning. This is a **new, separate check** (`HooksUsed` or similar; recorded,
non-gating, same tier as `KohaMaxVersion`/`GpgSignedTag`) rather than an extension of
`DependencyAllowlist` — it's not risky-by-default the way shelling out is, it's simply informational
surface area worth showing an installing admin.

### 4. Surfacing to the installing admin

Two audiences, two places:

- **On the plugin's store page** (buildable now, no Koha-core changes needed): declared
  capabilities with their reasons, and detected hooks, alongside the existing certification badge.
  An admin evaluating whether to install can already read this before ever touching Koha.
- **In Koha's own install/upgrade flow** (needs Koha core changes, see below): a consent screen
  shown before a `.kpz` is installed or upgraded, summarizing the same two lists, requiring an
  explicit accept. This is the harder half — Koha needs to parse the new `capabilities` metadata
  field itself (not just the store), and the plugin installer UI needs a new interstitial step.
  Doesn't yet exist even as a Bugzilla RFC; needs one before implementation starts, since it's a
  Koha core change, not a store-side one.

### Phasing

1. **Store only** — `capabilities` metadata parsing, `DependencyAllowlist` cross-reference logic,
   `HooksUsed` check, plugin-page surfacing. Fully deliverable within `koha-plugin-store`, no
   dependency on Koha core, and immediately unblocks any plugin with a genuine need that's been
   hitting the hard gate.
2. **Koha core RFC** — new metadata field Koha's plugin system understands, install/upgrade-time
   consent UI. Independent, slower-moving, degrades gracefully: older Koha versions simply never
   show the consent screen and install exactly as they do today, since the field is additive
   metadata, not a required one.

Phase 1 is genuinely useful on its own — it turns "declare and verify" into a real path even before
any admin-facing consent screen exists.

## Open questions

- **Declaration granularity.** Plugin-metadata-level (one `capabilities` list covering the whole
  plugin) vs. inline per-call-site annotations (e.g. `## qa-allow: system_call -- reason` next to
  the actual call). Metadata-level is simpler to implement and matches how `minimum_version`/
  `license` already work, but one declared `system_call` capability justifies *any* `system()` call
  anywhere in the plugin, not just the one the author had in mind. Inline is more precise and
  survives refactors/audits better (a new, unrelated `system()` call added later wouldn't silently
  inherit an old justification) but needs its own parser and is more machinery to build. Leaning
  metadata-level for phase 1 given the smaller lift, revisit if declared-but-unrelated usage turns
  out to be a real problem in practice.
- **Reason quality.** Nothing stops an author writing `reason => 'needed'`. This design surfaces
  the reason for a human (installing admin, eventually a community reviewer) to judge — it doesn't
  attempt to validate reason quality automatically. That's a reasonable v1 boundary: the goal is
  informed consent, not automated trust scoring.
- **Stale declarations across versions.** A capability declared in version 1.0 that's removed from
  the code in 1.1 should probably stop appearing without the author explicitly pruning it — needs
  deciding whether `review_checks` diff-detects this or it's left as author hygiene.

## Deferred work (unchanged from check-pipeline-design.md)

This does **not** address `DependencyAllowlist`'s already-known limitation that a determined,
dishonest plugin could declare a false reason, or obfuscate a risky call so the pattern scan misses
it entirely (and therefore never prompts a declaration at all). Both are the same class of problem
as check-pipeline-design.md's deferred "dynamic sandboxed behavioural auditing" item — this design
is about honest disclosure for legitimate use, not adversarial detection, and doesn't change that
tradeoff.
