# Conveyor Schema Registry

This directory is the local registry for Phase 0/1 public artifact schemas. The registry is intentionally small, strict, and versioned so Conveyor can reject ambiguous plan and evidence data before stochastic agents act on it.

`registry.json` is the machine-readable registry index. The table below mirrors it for readers.

## Registered Versions

| Artifact | Version | Schema |
| --- | --- | --- |
| Conveyor human plan | `conveyor.plan@1` | `conveyor.plan.v1.schema.json` |
| Run specification | `run_spec@1` | `run_spec.v1.schema.json` |
| Station plan | `station_plan@1` | `station_plan.v1.schema.json` |
| Evidence record | `evidence@1` | `evidence.v1.schema.json` |
| Review record | `review@1` | `review.v1.schema.json` |
| Gate decision | `gate@1` | `gate.v1.schema.json` |
| Run bundle index | `run_bundle@1` | `run_bundle.v1.schema.json` |

Every artifact carries a required `schema_version` field whose value must exactly match one registered version. Unknown artifacts and unsupported versions are hard failures; Conveyor must emit a structured finding instead of best-effort parsing.

## Compatibility Notes

Schema version `@1` is the Phase 0/1 compatibility line. Compatible changes may clarify descriptions, tighten examples, or add optional fields only when consumers can ignore them without losing auditability. Incompatible changes require a new schema version and golden examples for both accepted and rejected payloads.

Required fields must not be weakened without updating the verification matrix in `conveyor-quality-ci-evals-vmr.13`. The schemas are public contracts for the deterministic conductor; stochastic agents may propose payloads, but the registry decides whether those payloads can enter a run.

## Golden Examples

Valid examples live in `examples/valid/`. Invalid examples live in `examples/invalid/` and deliberately omit a required field while keeping `schema_version` correct. The validator also synthesizes unsupported-version and unknown-version payloads to prove those paths fail explicitly.

## Verification

Run:

```bash
python3 scripts/validate_schema_registry.py
```

The command emits JSON with one finding per schema, example, and version-failure check. A non-zero exit means at least one schema, golden example, or explicit version rejection path is broken.
