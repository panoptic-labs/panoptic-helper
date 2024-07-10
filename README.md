# PanopticHelper

## Installation

Panoptic uses the Foundry framework for testing and deployment, and Prettier for linting.

To get started, clone the repo and install the pre-commit hooks.

```bash
git clone https://github.com/panoptic-labs/panoptic-v1-helper.git --recurse-submodules
npm i
```

## Testing

Run the Foundry test suite:

```bash
forge test
```

Get a coverage report (requires `genhtml` to be installed):

```bash
forge coverage --report lcov && genhtml lcov.info --branch-coverage --output-dir coverage
```
