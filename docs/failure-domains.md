# Failure domains: Keeper, replicas, and topology

Scenario 1 and Scenario 2 in the [README](../README.md) measure two *different*
failures. This doc explains why they are different, and what changes if you
collapse the topology.

> Everything in the README is measured against the running lab. This doc is
> mostly reasoning about the same system — the INSERT path and the tolerance
> tables below follow from the quorum model, not from a fresh run.

## Why Keeper is on the critical path of every INSERT

An INSERT into a ReplicatedMergeTree contains **two different waits**, and
`insert_quorum` only controls the second one.

```
client ──INSERT──> chi-0
                     │
                     ├─ 1. split rows into blocks, hash each block
                     │
                     ├─ 2. write the part to chi-0's local disk (temp part)
                     │
                     ├─ 3. ★ Keeper round-trip — synchronous, never skippable ★
                     │      ├─ check the block hash        → deduplication
                     │      ├─ register the part under this replica
                     │      └─ append an entry to the replication log
                     │
                     ├─ 4. commit temp part → active part
                     │
                     ├─ 5. ☆ wait for other replicas to report the fetch ☆
                     │      insert_quorum = 0  → skipped entirely
                     │
                     └─ 6. ack the client
```

Step 3 happens on every INSERT no matter what `insert_quorum` is set to.
Step 5 is the only thing `insert_quorum` governs.

Step 3 cannot be skipped because **Keeper holds the authoritative metadata** for
a replicated table: the replication log, the dedup block hashes, and the
per-replica part registry all live there. A part written to local disk but not
recorded in Keeper would be invisible to every other replica — replication would
simply be broken.

That is the real reason a table goes read-only when Keeper loses quorum. It is
not a safety decision made by the quorum setting; there is nowhere to record the
write.

### Two independent axes

|  | Keeper availability | `insert_quorum` |
| --- | --- | --- |
| Question it answers | Can this write be **recorded** at all? | How many **data copies** before the ack? |
| Failure surfaces as | `TABLE_IS_READ_ONLY` (or a hang) | `TOO_FEW_LIVE_REPLICAS` |
| Driven by | Keeper ensemble quorum | count of live replicas |
| Shape | binary (writable / read-only) | graded (1, 2, 3, `auto`) |

All four combinations exist. Notably, `insert_quorum = 0` does **not** rescue a
Keeper outage — Scenario 2 hit `TABLE_IS_READ_ONLY` while running the stock `0`.

### Metadata durability is not data durability

With `insert_quorum = 0` you still get strong *metadata* durability for free:
Keeper is itself a 3-node replicated ensemble, so "part X exists on chi-0" is a
quorum-backed fact. But the *data* exists in one copy.

Lose that replica permanently and you land in the worst of both: Keeper insists
the part should exist, the other replicas chase a fetch that can never succeed,
and the replication queue stalls. `insert_quorum` is the only knob that controls
how many copies of the actual bytes exist at ack time.

## ZooKeeper vs ClickHouse Keeper

ClickHouse Keeper implements the **ZooKeeper client protocol**. The proof is in
this repo: ClickHouse points at Keeper using the `<zookeeper>` tag in
[`k8s/20-clickhouse.yaml`](../k8s/20-clickhouse.yaml) — the server does not know
or care which implementation answers. The only visible difference is the port
(Keeper 9181, ZooKeeper 2181).

So the znode data model, ephemeral/sequential nodes, watches, and the
linearizable-write guarantee are the same, and **every result in Scenario 2 would
reproduce identically on ZooKeeper** — those behaviours come from the quorum
model, not the implementation.

| | ZooKeeper | ClickHouse Keeper |
| --- | --- | --- |
| Runtime | Java / JVM | C++, in the ClickHouse codebase |
| Consensus | ZAB | Raft (NuRaft) |
| Memory footprint | higher | noticeably lower for the same data |
| Snapshots | uncompressed | compressed |
| Config | `zoo.cfg` properties | ClickHouse XML (`<keeper_server>`, `<raft_configuration>`) |
| Deployment | always a separate process | standalone **or** embedded in `clickhouse-server` |
| Migration | — | `clickhouse-keeper-converter` reads ZK snapshots/logs |

### The difference that matters for DR: GC pauses

ZooKeeper runs on the JVM and is subject to **stop-the-world GC**. A pause longer
than `session_timeout_ms` (30000 here) expires the sessions, and ClickHouse sees
exactly what it would see if Keeper had genuinely died: `is_session_expired = 1`,
tables read-only, writes blocked.

ZooKeeper therefore has an entire failure class that has nothing to do with
machines failing — the Scenario 2 outage, triggered by garbage collection alone,
and more likely the larger the cluster gets. Keeper is C++ and does not have it.

## Topology: what co-locating actually costs

### This lab shares nodes already

Worth being precise about what is and is not separated here:

```
worker    worker2   worker3
chi-0     chi-1     chi-2      <- separate pods
chk-0     chk-2     chk-1      <- separate pods, same nodes
```

Both StatefulSets spread across the same three workers, so **each worker already
holds one ClickHouse replica and one Keeper member**. The separation is at the
*pod* level, not the *node* level — which is exactly why Scenario 1 kills one
replica and one Keeper member at once.

A production topology that genuinely separates the domains would pin Keeper to
its own nodes (taints/tolerations or a `nodeSelector`) so that ClickHouse load
and ClickHouse node failures cannot touch the coordination layer.

### If Keeper were a container inside the ClickHouse pod

Node-level failure math **does not change**, because the two are already
co-located per node:

| | separate pods, same node (today) | same pod |
| --- | --- | --- |
| one node down | lose 1 replica + 1 Keeper member | lose 1 replica + 1 Keeper member |
| Keeper | 2/3, quorum held | 2/3, quorum held |
| writes | fine | fine |

What changes is that every *sub-node* failure becomes coupled. Four consequences,
roughly in order of how likely they are to bite:

**1. Scenario 2 becomes untestable.**
`scripts/test-keeper-quorum-loss.sh` induces quorum loss with
`kubectl scale sts chk --replicas=1`. Without its own StatefulSet that lever is
gone: killing two Keeper members means killing two ClickHouse replicas too. The
two failure domains can no longer be varied independently — and the README's
conclusion that *Keeper quorum, not replica count, is the write-availability
boundary* is precisely what you can no longer demonstrate.

**2. A routine config change can interrupt writes.**
Applying a ClickHouse-only ConfigMap change needs
`kubectl rollout restart statefulset/chi`, which would now cycle the whole Keeper
ensemble. A StatefulSet rolls one pod at a time, which *should* keep 2/3 — but it
advances on the readiness probe, and the probe here is

```yaml
readinessProbe:
  httpGet: { path: /ping, port: 8123 }
```

which only checks ClickHouse's HTTP port and says nothing about whether Keeper
has rejoined the Raft quorum and caught up. ClickHouse answers `/ping` in
seconds, the rollout moves to the next pod, and the ensemble can transiently drop
to 1/3 — a self-inflicted write outage during a routine change. Avoiding it
requires a readiness probe that also covers Keeper (e.g. the `mntr`
four-letter-word command).

**3. ClickHouse load degrades Keeper.**
Keeper's Raft log needs low-latency `fsync`. ClickHouse merges saturate disk I/O.
On a shared pod and disk:

```
large merge / heavy query  → disk I/O saturated
                           → Raft log fsync latency spikes
                           → Raft heartbeat timeouts
                           → spurious leader elections, or session expiry
                           → TABLE_IS_READ_ONLY
```

Scenario 2's symptom with no machine having failed — the same shape as the
ZooKeeper GC pause above, with I/O contention as the cause instead of GC, and
ClickHouse knocking over the coordination layer it depends on. Note the `chi`
container currently sets no resource requests or limits, which makes contention
and whole-pod eviction under memory pressure more likely.

**4. Scaling is locked to 1:1.**
Keeper wants a small odd ensemble (3 or 5; more members mean slower writes).
ClickHouse replicas scale for read throughput and capacity. These are unrelated
drivers, and one pod forces them equal:

| desired replicas | forced Keeper members | result |
| --- | --- | --- |
| 5 | 5 | slower Raft writes for no benefit |
| 4 | 4 | **even ensemble** — quorum 3/4 still tolerates only 1 loss, at higher latency; strictly worse than 3 |
| 2 | 2 | quorum 2/2 — **any single failure stops writes** |

Scaling down to 2 is the trap: it looks like a cost saving and silently takes
node tolerance from 1 to 0.

**When co-location is fine:** local development, CI, single-machine demos —
anywhere there is no availability requirement to begin with.

## Node-down tolerance

For the 3-replica layout in this lab (either topology — the numbers are the
same):

| nodes down | replicas | Keeper | quorum (needs 2) | writes | reads |
| --- | --- | --- | --- | --- | --- |
| 0 | 3/3 | 3/3 | yes | yes | yes |
| **1** | 2/3 | 2/3 | yes | yes | yes |
| 2 | 1/3 | 1/3 | **no** | `TABLE_IS_READ_ONLY` | yes |
| 3 | 0/3 | 0/3 | no | no | no |

**Write tolerance is 1 node.** Two independent limits happen to bind at exactly
the same point in a symmetric 3+3 layout — Keeper quorum needs 2 of 3, and
`insert_quorum = auto` also needs 2 of 3 — so neither is the weak link. That is a
coincidence of the 3+3 shape, not a general rule.

"Tolerance 1" is a statement about *writes*. Three different numbers apply:

| Property | Tolerance | Why |
| --- | --- | --- |
| Write availability | 1 | Keeper quorum and `insert_quorum` bind together |
| Read availability | **2** | reads never touch Keeper; one live replica can answer |
| Data durability | 1 | `auto` puts acked data on ≥2 of 3 replicas |

Read tolerance of 2 is measured: in Scenario 2, with Keeper at 1/3 and the tables
read-only, `SELECT count()` still returned 1520.

Durability deserves care. `auto` guarantees an acked write is on **2 of 3**
replicas — so if two nodes are lost *permanently*, the single survivor may be the
one that never received it, and acked data can still be lost. With three replicas
you cannot have both write-availability tolerance 1 and durability tolerance 2:
surviving two permanent losses requires `insert_quorum = 3`, which drops write
tolerance to **0**. This is the same trade the README flags — a hard
`insert_quorum = 3` converts any single-node failure into a full write outage.

### Can Keeper's quorum be lowered to tolerate more?

No — and the asymmetry with `insert_quorum` is the point.

`insert_quorum` is tunable because it expresses a trade *you* own: how many data
copies to wait for before acking. Keeper's quorum is not a setting at all. A
majority is a mathematical requirement of the consensus algorithm, and there is
no knob to set "quorum = 1 of 3".

The reason is split-brain. Majority is precisely the property that makes it
impossible for two disjoint groups to both believe they have quorum. Allow a
quorum of 1 in a 3-member ensemble and a network partition gives you two Keeper
groups independently accepting writes to the same replication log — divergent
metadata with no way to reconcile it. Losing writes is recoverable; two
authoritative histories of the same table is not.

So the **only** lever on Keeper tolerance is the number of members:

| Members | Quorum | Node-down tolerance |
| --- | --- | --- |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | **2** |
| 6 | 4 | 2 |
| 7 | 4 | 3 |

Tolerance is `floor((N-1)/2)`. Even sizes buy nothing — 4 members tolerate the
same single loss as 3 while making every write wait for one more ack, which is
why ensembles are always odd. And bigger is not free: every write needs a
majority to acknowledge, so latency grows with N. 5 is the usual answer for
production; 7 is rarely worth it.

### Settings that sound like they help, but do not

| Setting | What it actually does |
| --- | --- |
| `quorum_reads` | Routes reads through the Raft log for linearizability instead of serving them locally. Read *consistency*, not fault tolerance — and it makes reads slower. |
| `session_timeout_ms` | How long before a dead session is declared dead. Changes detection *speed*, not how many nodes may fail. Raising it rides out transient blips at the cost of slower failure detection. |
| `operation_timeout_ms` | Per-operation deadline. Same story. |
| `election_timeout_*_ms`, `heart_beat_interval_ms` | How quickly a new leader is elected (~20s in Scenario 1). Affects recovery *time*, not tolerance. |
| `force_sync` | Whether to fsync the Raft log on every write. A durability/latency trade; turning it off risks losing committed entries on power loss. |
| non-voting members (learners) | Receive the log but are excluded from quorum by definition, so they change tolerance neither up nor down. Useful for read fan-out, not availability. |

None of these move the tolerance number. Only member count does.

### Getting to tolerance 2

Five nodes, one replica and one Keeper member each:

```
Keeper:                 5 members, quorum 3  → tolerates 2
insert_quorum = auto:   5 replicas, majority 3 → tolerates 2
```

This is also where separating the two StatefulSets pays off concretely: deployed
apart, you can raise **only** Keeper to 5 while leaving ClickHouse at 3, buying
coordination-layer tolerance of 2 without paying for two more ClickHouse
replicas. One pod per node with both inside forecloses that option.

Growing an existing ensemble is a membership change, not a config edit. Recent
Keeper versions support online reconfiguration; either way, add members **one at
a time**, waiting for each to join and catch up before adding the next, so the
quorum requirement never outruns the members that are actually caught up.
