This repo hosts the scripts and mapping file needed to translate the raw MAgPIE outputs to a land use emulator for MESSAGEix-MAgPIE linkage.
First, run the emulator.sh first to generate the emulator.
Then, run the add_woodfuel.sh to add additional biomass supply from forest harvest. (this step is separate as it needs variable that is currently not reported from report.mif, and need access to output.gdx)
For MESSAGEix linkage, use the output from add_woodfuel.sh
