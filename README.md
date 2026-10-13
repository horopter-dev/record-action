# Horopter record

Records a workflow step as a [Horopter](https://github.com/horopter-dev/horopter) change: when it
started, when it ended, and whether it completed or failed. Swap `run:` for this action and name
the thing the step changes:

```yaml
- uses: horopter-dev/record-action@v1
  with:
    subject: acme/prod
    key: ${{ secrets.HOROPTER_INGRESS_KEY }}
    url: ${{ vars.HOROPTER_INGRESS_URL }}
    run: ./deploy.sh prod
```

The step runs `run` under `horo run`, which posts the change's start, runs the command with
`bash -e`, and posts its outcome. The step's exit code is the command's.

**Recording never blocks the work.** If Horopter cannot be reached, the key is empty, or `horo`
cannot be downloaded, the command runs anyway, unrecorded, with a warning. Set `strict: true` to
fail the step instead, without running the command.

## Inputs

| input          | required | default                                                    |
| -------------- | -------- | ---------------------------------------------------------- |
| `run`          | yes      | the command, executed by `bash -e`                         |
| `subject`      | yes      | the thing changed, e.g. `acme/prod`; a repository is not one |
| `type`         | no       | `deployment`                                               |
| `name`         | no       | appended to the ref; required in a matrix job              |
| `title`        | no       | `<workflow> / <job>`                                       |
| `actor`        | no       | the actor that triggered the run                           |
| `attributes`   | no       | extra `key=value` lines, after the automatic ones          |
| `url`          | no       | `HOROPTER_INGRESS_URL` from the environment                |
| `key`          | no       | `HOROPTER_INGRESS_KEY` from the environment                |
| `strict`       | no       | `false`                                                    |
| `horo-version` | no       | the `horo` this release pins                               |

Every change carries four attributes that lead back to its run: `sha`, `git_ref`, `workflow`
and `run_url`. An `attributes` line with the same key replaces one.

A composite action cannot read `secrets`, so pass the key as `key:` or set
`HOROPTER_INGRESS_KEY` in the job's `env:`. Use a producer key issued for this repository.

## The change's ref

The ref is `<owner>/<repo>/<run_id>/<attempt>/<job>`, with `/<name>` appended when `name` is set.
A re-run is a new attempt, so it records a new change.

Every leg of a matrix shares one job, so in a matrix `name` is required, and the step fails
before running anything without it:

```yaml
strategy:
  matrix:
    region: [eu, us]
steps:
  - uses: horopter-dev/record-action@v1
    with:
      subject: acme/prod-${{ matrix.region }}
      name: ${{ matrix.region }}
      key: ${{ secrets.HOROPTER_INGRESS_KEY }}
      url: ${{ vars.HOROPTER_INGRESS_URL }}
      run: ./deploy.sh ${{ matrix.region }}
```

The step summary names the stored ref and the outcome, e.g.
"recorded `github/acme/api/123/1/deploy` (completed)", or says why the change was not recorded.

## `horo`

Each release pins one `horo` release and the sha256 of each platform's build. The action
downloads it from `horopter`'s GitHub release, checks it against that sha256, and keeps it in the
runner's tool cache. A `horo-version` override is checked against that release's `checksums.txt`
instead, and must be 0.11.0 or later, the first `horo` whose `run` reports what it recorded. A
file that does not match its sha256 is never run: the step fails, whatever `strict` says.

That `horo` is first on the `PATH` of the `run` command and of the job's later steps.

## Limits

- **Runners:** Linux x64 and arm64, and macOS arm64. On any other runner the command runs
  unrecorded, or the step fails under `strict`.
- **Only `run:` steps.** A step that `uses:` another action cannot be wrapped.

## Licence

Apache 2.0; see [`LICENSE`](LICENSE).
