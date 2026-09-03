# JSON Schema corpus

The runner executes the complete local Draft 2020-12 and Draft 7 groups from
the official JSON-Schema-Test-Suite revision pinned in `corpus.json`. Draft 7
schemas receive the canonical dialect declaration before validation because
an absent `$schema` intentionally defaults to 2020-12 in the product.

The runner never starts the suite's HTTP server and never resolves external
documents. Allowlisted cases are limited to schemas that require those
unavailable external documents; unexpected failures and stale entries fail the
run.

Run it against an exact checkout:

```sh
bun tests/json-schema/run.ts /path/to/JSON-Schema-Test-Suite
```

Every external-document case must have a file/group/test entry and reason in
`corpus.json`.
