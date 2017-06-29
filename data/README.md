# Experiments and Data
There are three experiments -- ballooning performance, poc for guest-managed evictions and correctness experiments around ballooning.

## Ballooning Performance
This experiment measures the time to shrink and grow back the size of the SSD.

## POC for Guest-managed Evictions
This experiment compares the number of cache misses (read errors) for guest-managed evictions vs hypervisor-managed (uniformly random) evictions. Read the stage-2 report to know more about the read error semantics.

## Correctness Experiment
This experiment just confirms that the number of cache misses (read errors) is exactly equal to the number of sectors ballooned out from the vSSD device.
