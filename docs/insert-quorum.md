# How to change `insert_quorum`

Scenario 1 showed that `insert_quorum` is the one setting a single-node outage
actually bites. Four ways to change it, all verified against this lab.

## Scope: what kind of setting is this?

`insert_quorum` is a **query-level (user) setting** — it lives in
`system.settings`, not in `system.server_settings` (server config) and not in
`system.merge_tree_settings` (table engine settings). **ClickHouse has no
database-level scope at all**, so there is no way to say "database `dr` always
writes with quorum 2".

"Session level" is one rung on its precedence chain, not what the setting *is*.
Lowest to highest precedence, each overriding the one before:

| # | Level | How | Applies to |
| --- | --- | --- | --- |
| 1 | `users.xml` profile | `<profiles><default><insert_quorum>` | everyone on that profile; **needs a restart** |
| 2 | SQL settings profile | `CREATE SETTINGS PROFILE … SETTINGS` | a user/role; effective immediately |
| 3 | Session | `SET insert_quorum = 'auto'` | that connection onwards |
| 4 | Query | `INSERT … SETTINGS insert_quorum = 2` | one statement |

This repo sets level 1, so `auto` is a **cluster-wide default**, not a database
setting.

### A default is not a guarantee

Because the value is resolved per INSERT, `insert_quorum` is **not a durability
property of the table**. Any client can send

```sql
INSERT INTO dr.rmt … SETTINGS insert_quorum = 0
```

and write non-quorum data into the same table; nothing in the table DDL prevents
it. Contrast with genuine table-level settings in the `ENGINE = … SETTINGS`
clause, which do bind to the table.

To make it non-overridable, add a constraint to the profile:

```xml
<profiles>
  <default>
    <insert_quorum>auto</insert_quorum>
    <constraints>
      <insert_quorum><readonly/></insert_quorum>
    </constraints>
  </default>
</profiles>
```

A client that then tries to override it is rejected rather than silently
downgraded. This repo does **not** set the constraint — the failure tests need
to override `insert_quorum` per query.

Check the effective value and whether anything changed it:

```sql
SELECT name, value, changed FROM system.settings WHERE name = 'insert_quorum';
```

## What stock `insert_quorum = 0` does

If nothing sets it, ClickHouse defaults to `0` — quorum writes **off**. The
INSERT is acked once:

1. the part is on the disk of the **one** replica that received the request, and
2. the corresponding entry is committed to Keeper.

It does **not** wait for any other replica to fetch the part; they pull it
asynchronously off the replication queue. So the durability of an acked write is
*one data replica plus Keeper metadata*.

That is the "the ack was a lie" case: if that replica is permanently lost before
another one fetches the part, the data is gone even though the INSERT returned
success — and worse, Keeper still says the part should exist, so the surviving
replicas retry the fetch forever and the replication queue stalls.

`insert_quorum = 0` does **not** mean "no coordination" — see
[`failure-domains.md`](failure-domains.md) for why Keeper is on the critical
path of every INSERT regardless of this setting.

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
[`k8s/20-clickhouse.yaml`](../k8s/20-clickhouse.yaml). This repo sets `auto`
there, so the whole lab defaults to a majority quorum:

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
| `insert_quorum_timeout` | `600000` (10 min) | Throws if quorum is not reached in time. Default is long — an INSERT that cannot reach quorum blocks for 10 minutes before failing; shorten it |
| `insert_quorum_parallel` | `1` | Parallel quorum inserts are allowed by default and are *not* linearizable. Must be `0` for `select_sequential_consistency=1` to mean anything |
| `select_sequential_consistency` | `0` | Read side: only return data known to have reached quorum |

## Verifying

```bash
./scripts/ch.sh 0 --query "SELECT value FROM system.settings WHERE name = 'insert_quorum'"
```

With three replicas up, `auto` resolves to a quorum of 2, so one node down is
still writable — which is the point of choosing it over a hard `insert_quorum=3`.
