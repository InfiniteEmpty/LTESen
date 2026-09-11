# Deferred work

This directory contains experiments that are intentionally excluded from the
active application and test paths.

`continuous_csi/` preserves the anchored interpolation, recursive 2-D
correlation, MUSIC/AR experiments, simulations, and their former unit tests.
The method is not currently part of `LteSensePipeline`; its dependencies and
numerical behavior are not maintained during the main receiver refactor.
