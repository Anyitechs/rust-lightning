# lightning-rapid-gossip-sync

This crate exposes functionality for rapid gossip graph syncing, aimed primarily at mobile clients.
Its server counterpart is the
[rapid-gossip-sync-server](https://github.com/lightningdevkit/rapid-gossip-sync-server) repository.

## Mechanism

The (presumed) server sends a compressed gossip response containing gossip data. The gossip data is
formatted compactly, omitting signatures and opportunistically incremental where previous channel
updates are known.

Essentially, the serialization structure is as follows:

1. Fixed prefix bytes `76, 68, 75` (the first three bytes are ASCII for `LDK`)
    - The purpose of this prefix is to identify the serialization format, should other rapid gossip
      sync formats arise in the future
2. Version byte
   - Currently supported versions are 1 and 2
3. Chain hash (32 bytes)
4. Latest seen timestamp (`u32`)
5. Version 2 only:
   - A byte indicating the number of default node features
   - An array of node features
6. An unsigned int indicating the number of node IDs to follow
7. An array of compressed node ID pubkeys (all pubkeys are presumed to be standard
   compressed 33-byte-serializations)
   - Version 2 only: Each pubkey is optionally followed by supplemental feature or address information.
8. An unsigned int indicating the number of channel announcement messages to follow
9. An array of significantly stripped down customized channel announcements
10. An unsigned int indicating the number of channel update messages to follow
11. A series of default values used for non-incremental channel updates
    - The values are defined as follows:
        1. `default_cltv_expiry_delta`
        2. `default_htlc_minimum_msat`
        3. `default_fee_base_msat`
        4. `default_fee_proportional_millionths`
        5. `default_htlc_maximum_msat` (`u64`, and if the default is no maximum, `u64::MAX`)
    - The defaults are calculated by the server based on the frequency among non-incremental
      updates within a given delta set
12. An array of customized channel updates

You will also notice that `NodeAnnouncement` messages are omitted altogether as the node IDs are
implicitly extracted from the channel announcements and updates.

The data is then applied to the current network graph, artificially dated to the timestamp of the
latest seen message less one week, be it an announcement or an update, from the server's
perspective. The network graph should not be pruned until the graph sync completes.

### Custom Node Announcement (V2 Only)

In version 2 of the RGS protocol, node IDs may be followed by supplemental feature and socket address data. The presence
of those additional fields is indicated by utilizing the unused bits of the 33-byte-pubkey parity byte as follows:

| 128             | 64       | 32           | 16           | 8            | 4            | 2          | 1                |
|-----------------|----------|--------------|--------------|--------------|--------------|------------|------------------|
| Additional data | Reminder | Feature data | Feature data | Feature data | Address data | Always set | Odd y-coordinate |

Note that bit indices 3-5 all indicate feature data. Specifically, if none of the bits are set, that means there is
no feature data that follows the pubkey. If a subset of them are set, the bit triplet is interpreted as an index (less
one) of the default node features that were supplied prior. If all three bits are set, a custom feature combination is
sent.

If there have been no changes to a node, bit index 6 can be set to function as a reminder absent any address or feature
data.

Lastly, bit index 7 indicates the presence of additional data, which will allow forwards compatibility.

### Custom Channel Announcement

To achieve compactness and avoid data repetition, we're sending a significantly stripped down
version of the channel announcement message, which contains only the following data:

1. `channel_features`: `u16` + `n`, where `n` is the number of bytes indicated by the first `u16`
2. `short_channel_id`: `CompactSize` (incremental `CompactSize` deltas starting from 0)
3. `node_id_1_index`: `CompactSize` (index of node id within the previously sent sequence)
4. `node_id_2_index`: `CompactSize` (index of node id within the previously sent sequence)

### Custom Channel Update

For the purpose of rapid syncing, we have deviated from the channel update format specified in
BOLT 7 significantly. Our custom channel updates are structured as follows:

1. `short_channel_id`: `CompactSize` (incremental `CompactSize` deltas starting at 0)
2. `custom_channel_flags`: `u8`
3. `update_data`

Specifically, our custom channel flags break down like this:

| 128                 | 64 | 32 | 16 | 8 | 4 | 2                | 1         |
|---------------------|----|----|----|---|---|------------------|-----------|
| Incremental update? |    |    |    |   |   | Disable channel? | Direction |

If the most significant bit is set to `1`, indicating an incremental update, the intermediate bit
flags assume the following meaning:

| 64                              | 32                              | 16                          | 8                                         | 4                               |
|---------------------------------|---------------------------------|-----------------------------|-------------------------------------------|---------------------------------|
| `cltv_expiry_delta` has changed | `htlc_minimum_msat` has changed | `fee_base_msat` has changed | `fee_proportional_millionths` has changed | `htlc_maximum_msat` has changed |

If the most significant bit is set to `0`, the meaning is almost identical, except instead of a
change, the flags now represent a deviation from the defaults sent at the beginning of the update
sequence.

In both cases, `update_data` only contains the fields that are indicated by the channel flags to be
non-default or to have mutated.

## Delta Calculation

The way a server is meant to calculate this rapid gossip sync data is by taking the latest time
any change, be it either an announcement or an update, was seen. That timestamp is included in each
rapid sync message, so all the client needs to do is cache one variable.

If a particular channel update had never occurred before, the full update is sent. If a channel has
had updates prior to the provided timestamp, the latest update prior to the timestamp is taken as a
reference, and the delta is calculated against it.

Depending on whether the rapid sync message is calculated on the fly or a snapshotted version is
returned, intermediate changes between the latest update seen by the client and the latest update
broadcast on the network may be taken into account when calculating the delta.

## Performance

Given the primary purpose of this utility is a faster graph sync, we thought it might be helpful to
provide some examples of various delta sets. These examples were calculated as of August 2024
with a network graph comprised of 80,000 channel announcements and 160,000 directed channel updates.

The processing times were averaged over 100 iterations on an iPhone 15 Pro.

| Full sync                   |        |
|-----------------------------|--------|
| Message Length              | 3.3 MB |
| Gzipped Message Length      | 1.5 MB |
| Client-side Processing Time | 407 ms |

| Week-old sync               |        |
|-----------------------------|--------|
| Message Length              | 1.7 MB |
| Gzipped Message Length      | 566 kB |
| Client-side Processing Time | 283 ms |

| Day-old sync                |        |
|-----------------------------|--------|
| Message Length              | 210 kB |
| Gzipped Message Length      | 99 kB  |
| Client-side Processing Time | 26 ms  |
