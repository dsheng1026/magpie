# vetting -- checks that run before MAgPIE does

Eleven cheap checks on what the pipeline can know before a single run is
submitted. Every one of them otherwise surfaces hours later: inside GAMS, once
per run, after a queue wait.

**Scope.** This gates a run before it starts. Whether the emulator's answers
agree with MESSAGE is a different question, checked after a run by
`messageix/optional/feedback_prep/` and `messageix/optional/feedback_run/`. Nothing here has an
opinion about it, and nothing here writes, moves or repairs what it finds.

## Usage

```
Rscript messageix/vetting/vet_pre_run.R --experiment default --stage 3 \
  --f56 messageix/optional/feedback_prep/output/default/f56_pollutant_prices.cs3
```

`--stage` is 1, 2 or 3 and decides which checks apply. `--warn-only` reports
failures and exits 0 instead of stopping. Every option is accepted as
`--key value` and as `--key=value`.

In process:

```r
source("messageix/vetting/vet_pre_run.R")
report <- vet_pre_run(pcfg, stage = 3, f56 = "...")
```

## Statuses

| Status | Meaning                                                        |
| ------ | -------------------------------------------------------------- |
| `PASS` | the condition holds                                            |
| `WARN` | worth reading before submitting; stops nothing                 |
| `FAIL` | a run started now fails, or runs silently on the wrong data    |
| `SKIP` | the check does not apply at this stage                         |

`vet_pre_run()` stops on any FAIL and returns the report as a data frame.

## The checks

| Check               | Stages | What it catches                                                        |
| ------------------- | ------ | ---------------------------------------------------------------------- |
| `magpie_root`       | 1-3    | run from somewhere that is not a MAgPIE model root                     |
| `default_cfg`       | 1-3    | `config/default.cfg` missing, or an SSP `setScenario()` does not carry  |
| `region_set`        | 1-3    | unknown region set, missing region-name table, two codes on one name    |
| `input_tarballs`    | 1-3    | tarballs absent locally, so a cluster job spends wall time downloading  |
| `patch_repo`        | 2-3    | a patch directory that cannot be created or written                     |
| `timesteps`         | 1-3    | a timesteps token that resolves to no model year                        |
| `bioenergy_floors`  | 2-3    | a demand minimum or first-generation subsidy flooring the price sweep   |
| `nonco2_cap`        | 3      | the non-CO2 cap read per tCO2 where the lever is per tC                 |
| `calibration_reuse` | 2-3    | no calibration run for the tau this stage reads                         |
| `f56_file`          | 3      | a GHG price file missing, mis-ordered, or short a scenario column       |
| `f60_seed`          | 3      | a bioenergy file that is already patched, or short its base columns      |

Three of them are worth a sentence each.

`bioenergy_floors` is a FAIL rather than a warning. `bioenergy_dem_min` and
`bioenergy_1st_subsidy` both act as a floor under the bioenergy price sweep, and
`pipeline_infrastructure.R` says so in its own notes on the two settings. A run
with either non-zero solves normally and produces a truncated sweep.

`nonco2_cap` warns on exactly one value. The lever is USD17MER per tonne of
carbon and the target it is usually set from is quoted per tonne of CO2, so 200
is the number the two readings collide on: 200 per tC is about 55 per tCO2, and
200 per tCO2 is 734 here. The check asks which was meant; it does not decide.

`f56_file` and `f60_seed` reuse `validate_f56()` and `assert_seed()` from
`messageix/R/pack_demand.R` rather than restating their conditions. Those two
functions are the contract, and a second copy of it here would drift.

## Wiring it into a run

`vet_pre_run()` is not called by anything yet. It is written to be the first line
of an experiment's run path, before the phase driver submits anything.

The call belongs in the phase driver, once per phase, after the experiment is
resolved and before the first run is assembled:

```r
source("messageix/vetting/vet_pre_run.R")
vet_pre_run(pcfg, stage = stage, f56 = f56)
```

That placement is a change to `messageix/R/run_phase.R`, which this module does
not make on its own. Until it lands, run the command by hand before submitting a
phase. Two properties make the call safe to add there: it is read-only, and it
stops on FAIL, so a driver that reaches its first `start_run()` has already
passed every check that applies.
