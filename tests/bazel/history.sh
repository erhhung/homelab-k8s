#!/usr/bin/env bash

# this is the poor man's version of the BuildBuddy
# history page because history is not available in
# BuildBuddy FOSS version web UI.

TIME_ZONE=${TZ:-America/Los_Angeles}
MAX_RESULTS=${1:-10}

kubectl exec -i -n postgresql postgresql-postgresql-0 -c postgresql -- \
  psql -U postgres -d buildbuddy -qtA --set="tz=$TIME_ZONE" <<SQL | jq
SET TIME ZONE :'tz';

SELECT
  COALESCE(
    jsonb_agg(
      to_jsonb(history) - 'sort'
      ORDER BY sort DESC
    ), '[]'::jsonb
  )
FROM (
  SELECT
    to_char(
      to_timestamp(created_at_usec / 1000000.0),
      'YYYY-MM-DD HH24:MI:SS TZ'
    ) AS date,
    COALESCE(
      NULLIF(bazel_exit_code, ''),
      'UNKNOWN'
    ) AS status,
    CONCAT(
      "user",
      CASE
        WHEN host IS NOT NULL AND host <> ''
          THEN CONCAT('@', LOWER(host))
        ELSE ''
      END
    ) AS user,
    CONCAT(command, ' ', pattern) AS command,
    CONCAT(
      'https://buildbuddy.fourteeners.local/invocation/',
      invocation_id
    ) AS url,
    created_at_usec AS sort
  FROM     public."Invocations"
  ORDER BY created_at_usec DESC
  LIMIT    $MAX_RESULTS
) AS history
SQL
