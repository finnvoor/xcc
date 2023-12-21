# ☁️ `xcc`
A CLI for Xcode Cloud

![Demo](https://github.com/Finnvoor/xcc/assets/8284016/e04488d2-8eb8-4e6c-80d6-55c7cf2ab82c)

## Installation
### Homebrew
```bash
brew install finnvoor/tools/xcc
```
### Mint
```bash
mint install finnvoor/xcc
```
### Manual
Download the latest release from [releases](https://github.com/Finnvoor/xcc/releases).

## Usage
### Authentication
`xcc` requires an API key from App Store Connect. Visit https://appstoreconnect.apple.com/access/api, create an API key with the "Developer" role, and either:
- Pass the Issuer ID, Private Key ID, and Private Key to `xcc` as flags:
  ```bash
  xcc --issuer-id <issuer-id> --private-key-id <private-key-id> --private-key <private-key>
  ```
- Set the Issuer ID, Private Key ID, and Private Key as env variables:
  ```bash
  export XCC_ISSUER_ID=<issuer-id>
  export XCC_PRIVATE_KEY_ID=<private-key-id>
  export XCC_PRIVATE_KEY=<private-key>
  ```

### Run a workflow
Running `xcc` will prompt you to select a product, workflow, and git reference. You can also pass the product, workflow, and reference using the `--product`, `--workflow`, and `--reference` flags.
```bash
xcc --product "Detail Duo" --workflow TestFlight --reference main
```
