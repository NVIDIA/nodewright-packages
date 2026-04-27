# Changelog

All notable changes to this package will be documented in this file.

## [0.3.0] - 2026-04-27

### Bug Fixes

- *(nvidia-tuned)* Verify containerd drop-in via LimitSTACK line match by [@ayuskauskas](https://github.com/ayuskauskas)

### New Features

- *(nvidia-tuned)* Add aks service profile for H100 on AKS by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Add AKS H100 inference override for kernel 6.8 by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- *(nvidia-tuned)* Extract service MAC-policy and bootloader helpers to common/ by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Bump version to 0.3.0 and document aks service by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Update directory structure tree for common/ and aks/ by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Add Unreleased section to CHANGELOG for aks service by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #39 from NVIDIA/feat/nvidia-tuned-aks

Update nvidia-tuned for aks by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #40 from NVIDIA/fix/tuned

Fix nvidia-tuned and nvidia-setup for eks-gb200 by [@ayuskauskas](https://github.com/ayuskauskas)

## [0.2.4] - 2026-04-15

### Bug Fixes

- Remove bootloader settings as they aren't very helpful in VMs by [@ayuskauskas](https://github.com/ayuskauskas)

### New Features

- *(nvidia-tuned)* Add a generic accelerator profile that is fairly minimal while still providing some benefits by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- Update project to follow the template by [@lockwobr](https://github.com/lockwobr)
- Merge pull request #37 from NVIDIA/feat/nvidia-tuned-generic

feat(nvidia-tuned): add a generic accelerator profile by [@ayuskauskas](https://github.com/ayuskauskas)

## [0.2.3] - 2026-03-09

### Bug Fixes

- Prepare profiles override and remove modules for gb200 by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Aws verify script for bad content check by [@ayuskauskas](https://github.com/ayuskauskas)

### New Features

- *(nvidia-tuned)* Change containerd drop to be a script by [@ayuskauskas](https://github.com/ayuskauskas)
- Prepare always runs and update aws script to support tuned lifecycle by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Update service to be eks to match aicr by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- Merge pull request #27 from NVIDIA/feat/nvidia-tuned/fix-containerd

feat(nvidia-tuned): change containerd drop to be a script by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #29 from NVIDIA/fix/nvidia-

Fix/nvidia by [@ayuskauskas](https://github.com/ayuskauskas)

## [0.2.2] - 2026-03-02

### Bug Fixes

- *(nvidia-tuned)* Set tuned to not reload profiles so it is final override by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- Merge pull request #24 from NVIDIA/fix/nvidia-tuned

fix(nvidia-tuned): set tuned to not reload profiles so it is final ov… by [@ayuskauskas](https://github.com/ayuskauskas)

## [0.2.1] - 2026-02-20

### Bug Fixes

- *(nvidia-tuned)* Work around for tuned needing update for executable bit by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Aws specific work arounds for bootloader and some values by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Add tests and fix common to os profiles by [@ayuskauskas](https://github.com/ayuskauskas)
- Bootloader by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- *(nvidia-tuned)* Update config file with the right version by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #19 from NVIDIA/add_validation

feat: add package validation for local and ci and developer docs by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Add link to gb200 tuning reference by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #21 from NVIDIA/testing

Add nvidia-tuned and unit-like integration tests for packages by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #22 from NVIDIA/nvidia-tuned-fix

Nvidia tuned fix by [@ayuskauskas](https://github.com/ayuskauskas)

## [0.2.0] - 2026-02-13

### New Features

- *(nvidia-tuned)* Add gb200 profiles by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- Merge pull request #18 from NVIDIA/nvidia-tuned-gb200

feat(nvidia-tuned): add gb200 profiles by [@ayuskauskas](https://github.com/ayuskauskas)

## [0.1.0] - 2026-02-12

### Bug Fixes

- Gh action by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Move the cleanup to the check step by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Cant actually remove the configmaps due to expected in config.json by [@ayuskauskas](https://github.com/ayuskauskas)

### New Features

- *(nvidia-tuned)* Move to be nvidia-tuned and make clear the support by [@ayuskauskas](https://github.com/ayuskauskas)
- Add attestation to package builds and update the readme for nvidia-tuned by [@ayuskauskas](https://github.com/ayuskauskas)

### Other Tasks

- Update nvidia-tuned readme by [@ayuskauskas](https://github.com/ayuskauskas)
- Update nvidia-tuned readme by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #16 from NVIDIA/tuned_h100

Add a package for nvidia hardware tunings by [@ayuskauskas](https://github.com/ayuskauskas)
- *(nvidia-tuned)* Fix version in example by [@ayuskauskas](https://github.com/ayuskauskas)
- Merge pull request #17 from NVIDIA/fix_nvidia-tuned

feat: add attestation to package builds and update the readme for nvi… by [@ayuskauskas](https://github.com/ayuskauskas)

<!-- Generated by git-cliff -->
