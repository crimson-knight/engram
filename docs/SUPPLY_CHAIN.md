# Supply chain: pinned and verified

Every input engram and its agent kit pull in is pinned to an exact version and
checked against a hash, so what runs is what was reviewed regardless of where
it was fetched from.

| Input | Pin | Verified by |
|---|---|---|
| Crystal shards (`db`, `sqlite3`) | exact versions in `shard.yml` (`= 0.13.1`, `= 0.21.0`) | `sha256` checksums in `shard.lock`, checked on every `shards-alpha install`; a mismatch aborts |
| engram source (Homebrew) | release tag in the formula `url` | `sha256` of the release tarball in the formula |
| engram source (git / plugin marketplaces) | release tag | the release's full commit hash, published in the GitHub release notes |
| Reader embedding model (optional) | `nomic-embed-text:v1.5` | the Ollama model digest `0a109f42…c45e59f`, checked before the first embedding; a mismatch refuses to run |
| Agent kit runtime | Ruby and Python standard library only | nothing to fetch |

## Installing a pinned release

From git, check out the tag and confirm the commit hash matches the one in
the release notes before running anything:

```sh
git clone --branch v0.2.0 https://github.com/crimson-knight/engram.git
cd engram
git rev-parse HEAD   # must equal the commit hash in the v0.2.0 release notes
shards-alpha install --frozen
integrations/install.sh --both
```

Codex can fetch the marketplace at an exact commit:

```sh
codex plugin marketplace add crimson-knight/engram --ref <commit hash from the release notes>
codex plugin add engram@engram-agent-kit
```

Never install from a branch name (`main`) in production; a branch moves.

## Changing a pin

1. Change the version in `shard.yml`, run `shards-alpha lock --update <shard>`,
   and review the new checksum in the `shard.lock` diff.
2. For the embedding model, pull the new tag, read its digest from
   `ollama list` / `/api/tags`, and update `MODEL` and `MODEL_DIGEST` together.
3. A pin change is its own reviewed commit. Do not bypass verification with
   `--skip-verify`.

Stock `shards` (as used by the Homebrew formula) honors the exact versions in
`shard.lock` but does not check the checksums; the formula's tarball `sha256`
covers engram's own source, and the exact shard versions cover the rest.
