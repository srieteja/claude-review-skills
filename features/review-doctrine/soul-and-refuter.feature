# language: en
Feature: Review doctrine and the gkc-style refuter
  The review process keeps its behavioural doctrine in SOUL.md, one file the owner can read and
  edit. The refuter reads the doctrine's Evidence, Severity and Checks sections and reviews the
  way gkc does: no claim without an anchor and an evidence class, docs drift and test bite are
  findings, and a refutation needs counter-evidence at the reviewed SHA.

  @race Two appliers, or a read while an apply is in flight, must not interleave: the applier
  holds an exclusive lock on ~/.reviews/soul.lock and writes through a temp file + rename;
  readers parse a consistent snapshot.
  @replay A replayed proposal id must not re-apply or duplicate a changelog entry; applied ids
  are journalled and a second apply is a no-op.
  @dos Doctrine size and proposal size are bounded: the parser refuses a file over 64 KiB and
  the applier refuses more than five rule changes in one proposal; a larger input fails before
  any model call.
  @forgery PR prose cannot become doctrine: proposals are built only from structured event
  records, never from quoted PR text, and a rule naming a gate id, rulebook or tool is rejected
  before it reaches the judge.
  @impersonation Model output cannot claim the owner's authority: only the local job writes a
  proposal, the applier accepts only that schema, the refuter has no doctrine write path and
  runs read-only.

  Scenario: The doctrine is parsed into sections and rules
    Given a SOUL.md with the sections Purpose, Evidence, Severity, Checks, Delivery, Review shape, Response protocol, Closure and Learning
    When soul.py parses it
    Then every rule is returned with its stable id, its text and its evidence count
    And prose outside rule lines is preserved

  Scenario: A missing required section is refused
    Given a SOUL.md without an Evidence section
    When soul.py parses it
    Then it exits non-zero naming Evidence

  Scenario: The immutable core cannot be edited by the learning job
    Given a proposal that edits the Evidence section
    When the applier applies it
    Then nothing is written and the refusal names the immutable section

  Scenario: An applied change is atomic and recorded
    Given a valid proposal for the Checks section
    When the applier applies it
    Then SOUL.md contains the new rule text
    And a snapshot of the previous file exists
    And the changelog has one entry with what, reasoning and evidence count

  Scenario: A replayed apply does not duplicate
    Given the same proposal id has already been applied
    When the applier runs again
    Then SOUL.md is unchanged and the changelog still has one entry

  Scenario: The refuter is given only the doctrine it acts on
    Given a SOUL.md whose sections have distinct markers
    When refute builds its prompt for a claim
    Then the prompt contains the Evidence, Severity and Checks sections
    And it does not contain Delivery or Response protocol

  Scenario: The refuter fails closed without a doctrine
    Given no doctrine file at the configured path
    When refute runs
    Then it exits non-zero before any model call

  Scenario: A verdict records the lens and the evidence
    Given a claim that a test stays green without the fix
    When the refuter confirms it by mutation
    Then the verdict is CONFIRMED with lens "test-bite"
    And the verdict quotes the mutation result as evidence

  Scenario: A refutation without counter-evidence is not a pass
    Given a claim the refuter cannot check
    When it returns a verdict
    Then the verdict is UNVERIFIABLE, not REFUTED
