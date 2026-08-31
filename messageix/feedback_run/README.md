# feedback_run -- the MAgPIE side of the emulator feedback check

Takes what `messageix/feedback_prep/` produced, runs MAgPIE against it, and puts
the result next to MESSAGE's own land-use output in one table.

**Scope.** This runs the comparison and writes it down. It does not interpret a
mismatch and does not decide what to change when the two sides disagree.

## The loop

```
MESSAGE run (emulator under test)
  -> messageix/feedback_prep/       f56_pollutant_prices.cs3
                                    f60_bioenergy_dem.cs3
                                    feedback_prep_manifest.csv
  -> start_feedback_run.R           one MAgPIE run on those two columns
  -> compare_land_use.R             land_use_comparison.csv
  -> a person
```

## Why it is not a new launch path

`start_feedback_run.R` builds its configuration with `stage_cfg(pcfg, 3, ...)`,
the same call the demand phase makes, and then replaces two settings:
`c56_pollutant_prices` and `c60_2ndgen_biodem` point at the column feedback_prep
wrote. Everything else, including the non-CO2 price cap and the tarball
bookkeeping, is whatever the demand phase does.

That matters more than it looks. A feedback run assembled independently would
differ from the runs it is meant to check in some switch nobody was tracking, and
the comparison would be measuring that difference instead of the emulator. Because
`stage_cfg()` insists on a point of the sweep grid, the run borrows the first
bioenergy and GHG price level and then overwrites both scenario columns; neither
level reaches the model.

**Decided 2026-08-31, user-confirmed:** borrowing the grid's first point this way
is the accepted approach. A feedback run does not get a grid-free stage of its
own.

The two files are packed with `pack_patch(files, pcfg, 3)`, so the tarball is
content-hashed like every other patch in this pipeline. Rebuild a file and the
name changes, which is the only reason MAgPIE unpacks it again rather than
proceeding on the previous run's data.

The prep step's own assumptions travel into every run started here: the variable
names it read the MESSAGE output by, the currency deflator, and the GWP values in
the pollutant map. They are listed in `messageix/feedback_prep/README.md` under
**Assumptions to confirm**, and recorded per run in
`feedback_prep_manifest.csv`. A comparison read without them is a comparison of
two things you have not checked are comparable.

## Usage

```
# after messageix/feedback_prep/feedback_prep.R has written its output
Rscript messageix/feedback_run/start_feedback_run.R --experiment default

# when the run has finished
Rscript messageix/feedback_run/compare_land_use.R \
  --run-dir output/<identifier>/feedback/feedback_feedback \
  --iamc    /abs/path/to/message_output.csv
```

`--dry-run` on the starter assembles and narrates the configuration without
calling `start_run()`. Every option is accepted as `--key value` and as
`--key=value`.

## Output

Written into `<run-dir>/feedback_comparison/`. The columns are specified in
`comparison_output_spec.md`; the short version is one row per variable, region
and year, carrying both models' values, their difference, and a flag where the
two units disagree.

**Decided 2026-08-31, user-confirmed:** the comparison table carries no
threshold, no tolerance and no verdict column, and it is not going to grow one.
What counts as an acceptable difference depends on the variable, on which of the
four or five emulators is under test, and on what the run is for. A number in
this file that looked like a pass mark would be read as one. A human judges the
mismatches.

## Files

| File                        | What it does                                          |
| --------------------------- | ----------------------------------------------------- |
| `start_feedback_run.R`      | packs the prep output and starts one MAgPIE run       |
| `compare_land_use.R`        | maps `report.mif` to MESSAGEix variables and compares |
| `comparison_output_spec.md` | the comparison table's columns and their meaning      |
