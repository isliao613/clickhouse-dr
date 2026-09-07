# How to change `insert_quorum`

Scenario 1 showed that `insert_quorum` is the one setting a single-node outage
actually bites. Four ways to change it, all verified against this lab.

## 1. Per query (ad hoc — the usual one)

```sql
INSERT INTO dr.rmt (id, val, ver) VALUES (1, 'a', 1) SETTINGS insert_quorum = 2;
INSERT INTO dr.rmt (id, val, ver) VALUES (2, 'b', 1) SETTINGS insert_quorum = 'auto';
```

## 2. Per session

```sql
SET insert_quorum = 'auto';
SELECT value FROM system.settings WHERE name = 'insert_quorum';
```

Applies to every subsequent statement on that connection only.

## 3. Over the HTTP interface

```bash
curl -sS 'http://localhost:8123/?insert_quorum=auto' \
  --data-binary "INSERT INTO dr.rmt (id, val, ver) VALUES (3, 'c', 1)"
```

## 4. As a permanent default

### (a) SQL settings profile — no restart, but not for `default`

```sql
CREATE SETTINGS PROFILE p_quorum SETTINGS insert_quorum = 'auto';
CREATE USER app IDENTIFIED WITH plaintext_password BY 'app' SETTINGS PROFILE p_quorum;
-- or attach to an existing SQL-created user:
ALTER USER app SETTINGS PROFILE p_quorum;
```

Takes effect immediately. It cannot be applied to the `default` user, which is
defined in `users.xml`:

```
Code 495. ACCESS_STORAGE_READONLY:
Cannot update user `default` in users.xml because this storage is readonly
```

### (b) `users.xml` profile — the cluster-wide default

The `default` profile lives in the `ch-config` ConfigMap in
[`k8s/20-clickhouse.yaml`](../k8s/20-clickhouse.yaml). The repo deliberately
ships the ClickHouse default (`insert_quorum` unset, i.e. `0`) so the failure
tests exercise stock behaviour; to make `auto` the cluster-wide default, add it
to that profile:

```xml
<profiles>
  <default>
    <insert_quorum>auto</insert_quorum>
    <select_sequential_consistency>0</select_sequential_consistency>
  </default>
</profiles>
```

**Gotcha:** the ConfigMap is mounted with `subPath`, and **`subPath` mounts do
not receive ConfigMap updates**. Measured here: 95s after editing the ConfigMap,
the file inside the pod was unchanged and `insert_quorum` was still `0`. The
rollout is mandatory:

```bash
kubectl -n ch apply -f k8s/20-clickhouse.yaml
kubectl -n ch rollout restart statefulset/chi
kubectl -n ch rollout status statefulset/chi --timeout=300s
```

After the restart all three replicas report `auto`.

Dropping `subPath` and mounting the whole `users.d/` directory instead would let
ClickHouse hot-reload the profile with no restart — at the cost of shadowing the
files the image ships in that directory.

## Related settings

| Setting | Default | Notes |
| --- | --- | --- |
| `insert_quorum` | `0` | `0` = off, `N` = that many replicas, `'auto'` = majority |
| `insert_quorum_timeout` | `600000` (10 min) | Throws if quorum is not reached in time. Default is long; shorten it |
| `insert_quorum_parallel` | `1` | Parallel quorum inserts are allowed by default and are *not* linearizable. Must be `0` for `select_sequential_consistency=1` to mean anything |
| `select_sequential_consistency` | `0` | Read side: only return data known to have reached quorum |

## Verifying

```bash
./scripts/ch.sh 0 --query "SELECT value FROM system.settings WHERE name = 'insert_quorum'"
```

With three replicas up, `auto` resolves to a quorum of 2, so one node down is
still writable — which is the point of choosing it over a hard `insert_quorum=3`.
