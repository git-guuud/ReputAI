# Deployment records

`sepolia.json` is written by the T6 scripts and is the handoff between them: `01_Commit`
records the operator registry, resolver and commitment; `02_Register` adds the registered
name, sandbox and verifier. It is committed once a live deployment exists, because the
addresses in it are the ones README.md points judges at.

`fork-test.json` is scratch output from `test/SepoliaDeployment.t.sol` and is gitignored —
the fork test sets `DEPLOYMENT_FILE` so a rehearsal can never overwrite a real record.
