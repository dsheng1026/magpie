*** |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
*** |  authors, and contributors see CITATION.cff file. This file is part
*** |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
*** |  AGPL-3.0, you are granted additional permissions described in the
*** |  MAgPIE License Exception, version 1.0 (see LICENSE file).
*** |  Contact: magpie@pik-potsdam.de

* Update v44_bii.l based on vm_bv.l
loop(i,
  loop(biome44,
    if(i44_biome_area_reg(i,biome44) <= 0,
      v44_bii.fx(i,biome44) = 0;
      v44_bii_missing.fx(i,biome44) = 0;
    else
      v44_bii.l(i,biome44) = 
        sum((cell(i,j),landcover44,potnatveg), vm_bv.l(j,landcover44,potnatveg) * i44_biome_share(j,biome44))
        / i44_biome_area_reg(i,biome44);
    );
  );
);
* smax() replaces the scalar check `s44_bii_target > 0` from bii_target.
* A guard is a condition that protects a code block from executing when it should not.
* Because i44_bii_target varies by (i,biome44), individual cells can be zero even when a policy
* is active (e.g. regions or biomes without a target). smax() checks whether any cell has a
* positive target, serving as the block-level guard before initialising the interpolation trajectory.

if (m_year(t) = s44_start_year AND smax((i,biome44), i44_bii_target(i,biome44)) > 0,
* The start value for the linear interpolation is the BII at biome level in the start year.
  p44_start_value(i,biome44) = v44_bii.l(i,biome44);
* The target value for the linear interpolation is the spatially resolved lower bound defined in `i44_bii_target(i,biome44)`.
* Replaces the uniform scalar s44_bii_target used in bii_target.
* Linear increase of BII target values at biome level from start year to target year, and constant values thereafter.
* The dollar operator acts as a cell-level guard: it restricts the interpolation assignment to only
* those (i,biome44) cells where a positive target has been set, skipping zero-target cells entirely.
* Without it, zero-target cells would produce a declining trajectory from p44_start_value toward zero,
* inadvertently imposing a downward BII pressure where no target was intended.
* This mirrors the role of the scalar guard `s44_bii_target > 0` in bii_target, which skips the
* entire block when no target is set -- here we need the check at the individual cell level instead.
  p44_bii_target(t2,i,biome44)$(i44_bii_target(i,biome44) > 0) = p44_start_value(i,biome44) + ((m_year(t2) - s44_start_year) / (s44_target_year - s44_start_year)) * (i44_bii_target(i,biome44) - p44_start_value(i,biome44));
  p44_bii_target(t2,i,biome44) = p44_start_value(i,biome44) + ((m_year(t2) - s44_start_year) / (s44_target_year - s44_start_year)) * (i44_bii_target(i,biome44) - p44_start_value(i,biome44));
  p44_bii_target(t2,i,biome44)$(m_year(t2) > s44_target_year) = i44_bii_target(i,biome44);
* Avoid implausible values
  p44_bii_target(t2,i,biome44)$(p44_bii_target(t2,i,biome44) >= 1) = 1;
  p44_bii_target(t2,i,biome44)$(m_year(t2) < s44_start_year) = 0;
  p44_bii_target(t2,i,biome44)$(i44_biome_area_reg(i,biome44) <= 0) = 0;
);

if (m_year(t) < s44_start_year,
 p44_bii_target(t,i,biome44) = 0;
else
  p44_bii_target(t,i,biome44) = p44_bii_target(t,i,biome44);
  if(c44_bii_decrease = 0,
    p44_bii_target(t,i,biome44)$(v44_bii.l(i,biome44) >= p44_bii_target(t,i,biome44)) = v44_bii.l(i,biome44);   
  );
);

