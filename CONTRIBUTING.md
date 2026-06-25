## Contribution Guidelines

Thank you for considering contributing to this project!
Contributions are always welcome and appreciated.

### How to Contribute

Please check the [issue tracker](https://github.com/CogitatorTech/zarr/issues) to see if there is an issue you
would like to work on or if it has already been resolved.

#### Reporting Bugs

1. Open an issue on the [issue tracker](https://github.com/CogitatorTech/zarr/issues).
2. Include information such as steps to reproduce the observed behavior and relevant logs or screenshots.

#### Suggesting Features

1. Open an issue on the [issue tracker](https://github.com/CogitatorTech/zarr/issues).
2. Provide details about the feature, its purpose, and potential implementation ideas.

### Submitting Pull Requests

- Ensure all tests pass before submitting a pull request.
- Write a clear description of the changes you made and the reasons behind them.

> [!IMPORTANT]
> It's assumed that by submitting a pull request, you agree to license your contributions under the project's license.

### Development Workflow

> [!IMPORTANT]
> If you're using an AI-assisted coding tool like Claude Code or Codex, make sure the AI follows the instructions in the [AGENTS.md](AGENTS.md) file.

#### Prerequisites

The recommended way to get a matching toolchain is the Nix package manager with flakes enabled.
The `make shell` command drops you into a development shell that pins Zig 0.16.0 and provides the supporting tools.

```shell
# Enter the Nix development shell
make shell
```

If you prefer not to use Nix, install GNU Make and a Zig 0.16.0 compiler yourself.
On Debian-based systems, GNU Make is available through the package manager.

```shell
# Install GNU Make on Debian-based systems
sudo apt-get install make
```

#### Code Style

- Use the `make format` command to format the code.
- Follow the writing and code conventions described in [AGENTS.md](AGENTS.md).

#### Running Tests

- Use the `make test` command to run the tests.

#### Building the Documentation

- Use the `make docs` command to generate the API documentation into `docs/api`.
- Use the `make docs-serve` command to generate and serve the documentation locally.

#### See Available Commands

- Run `make help` to see all available commands for managing different tasks.

### Code of Conduct

We adhere to the project's [Code of Conduct](CODE_OF_CONDUCT.md).
