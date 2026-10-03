_NOTE: files with names starting with dot are not copied_

* `auth-profiles.json` is obsolete since version 2026.9.5.

  Run command below to authenticate against Codex and store
  the access/refresh tokens in the internal SQLite database:

  ```bash
  openclaw models auth login \
    --provider openai \
    --method device-code \
    --profile-id openai:erhhung \
    --agent main
  ```
