# Comparison output specification

What `compare_land_use.R` writes, and what each column means. Two files, both
semicolon-separated, both in `<run-dir>/feedback_comparison/` unless `--out-dir`
says otherwise.

## `land_use_comparison.csv`

One row per variable, region and year that both models reported.

| Column                | Type | Meaning                                                                     |
| --------------------- | ---- | --------------------------------------------------------------------------- |
| `variable`            | chr  | MESSAGEix variable name, unit stripped, as `MM_linkage_mapping.csv` targets it |
| `region`              | chr  | MESSAGEix region name (`R12_AFR`, ...), from `messageix/data/region_names_R12.csv` |
| `year`                | int  | model year                                                                   |
| `magpie`              | num  | the feedback run's value, mapped out of `report.mif`                         |
| `magpie_unit`         | chr  | unit `write.reportProject()` assigned it                                     |
| `message`             | num  | the value in the MESSAGE output the run was prepared from                    |
| `message_unit`        | chr  | unit as reported by MESSAGE                                                  |
| `difference`          | num  | `magpie - message`, in `magpie_unit`                                         |
| `relative_difference` | num  | `difference / message`, `NA` where `message` is zero                         |
| `unit_mismatch`       | lgl  | `TRUE` where the two unit strings differ                                     |

`relative_difference` is `NA` rather than infinite where MESSAGE reports zero,
because zero is a real answer for several land-use variables and an infinity in a
csv tends to become a blank somewhere downstream.

`unit_mismatch` is a flag, not an error. The two models label some units
differently while meaning the same thing. It marks the rows to look at before
reading anything into their difference.

## `comparison_coverage.csv`

One row per variable that only one side reported.

| Column        | Type | Meaning                                             |
| ------------- | ---- | --------------------------------------------------- |
| `variable`    | chr  | MESSAGEix variable name                             |
| `reported_by` | chr  | `magpie only` or `message only`                     |

Both sides are read over the full target vocabulary of
`MM_linkage_mapping.csv`, so a variable missing from one model appears here
instead of quietly dropping out of the join. An empty file means the two models
covered the same variables.

## What is not in either file

No threshold, no tolerance, no pass or fail column, and no ranking of which
differences matter. That reading is the point of the exercise and it stays with
the person doing it.

**Decided 2026-08-31.** This is settled, not an open question:
the table stays verdict-free and a human judges the mismatches. Treat a request
to add a tolerance column as a change of scope, not a gap to fill.

## Reproducing a comparison

`feedback_prep_manifest.csv`, written beside the prep output, records the MESSAGE
file, the weighting rule, the deflator, the pollutant map and the bioenergy
variables the run was fed. A comparison is only interpretable next to it, so keep
the two together.
