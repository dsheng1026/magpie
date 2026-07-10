*** |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
*** |  authors, and contributors see CITATION.cff file. This file is part
*** |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
*** |  AGPL-3.0, you are granted additional permissions described in the
*** |  MAgPIE License Exception, version 1.0 (see LICENSE file).
*** |  Contact: magpie@pik-potsdam.de

scalars 
 c44_bii_decrease       Implementation of target for BII (binary)               / 0 /
 s44_target_year        Year in which the BII target is reached  (1)           / 2100 /
 s44_start_year         Start year for interpolation towards BII target (1)    / 2030 /
 s44_cost_bii_missing   Technical costs for missing BII increase (USD17MER per unit of BII)  / 1e+07 /
 ;

table f44_bii_target(i,biome44) Spatially resolved BII target by region and biome (1)
$ondelim
$include "./modules/44_biodiversity/bii_spatially_resolved/input/f44_bii_target.csv"
$offdelim
;

table fm_bii_coeff(bii_class44,potnatveg) Biodiversity Intactness Index coefficients (unitless)
$ondelim
$include "./modules/44_biodiversity/bii_spatially_resolved/input/f44_bii_coeff.cs3"
$offdelim
;

* Replaces scalar s44_bii_target from bii_target: targets are read per region and biome from CSV.
* s44_bii_target is therefore not declared in this realization.

table f44_biome_area(j,biome44) Area of biome type in each spatial unit (mio. ha)
$ondelim
$include "./modules/44_biodiversity/bii_spatially_resolved/input/biorealm_biome.cs3"
$offdelim
;
