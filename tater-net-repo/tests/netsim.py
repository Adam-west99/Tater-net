#!/usr/bin/env python3
"""
Timing and network simulator for TaterNet-OnlineCoop.

Re-implements the mod's client input sampling (client/mirror_view.gd), host
input handling (core/online_coop.gd) and snapshot chunking/reassembly, then
runs them against different frame-rate profiles (Mac ProMotion, Windows 60 /
144 Hz, stuttering low-end PCs) and network conditions (lag, jitter, loss,
reordering).

It tests the mod's own logic, not Brotato or Godot itself.

    python3 tests/netsim.py           # run every scenario, print a report
    python3 tests/netsim.py --v1      # also run the original input protocol
"""
import random
import zlib
import statistics
import sys

SEND_INTERVAL = 1000.0 / 30.0  # client sends input at 30 Hz
INPUT_TIMEOUT = 1000.0         # host releases everything after 1 s silence
CHUNK = 1100                   # snapshot chunk payload bytes
SECONDS = 120

# ---------------------------------------------------------------- profiles

def frames(profile, rng, duration_ms):
    """Yield frame timestamps (ms) for a machine profile."""
    t = 0.0
    while t < duration_ms:
        if profile == "mac_promotion_120":
            # ProMotion: mostly 120 Hz, sometimes drops to 80/60 Hz.
            dt = rng.choice([8.33] * 8 + [12.5, 16.67])
            dt += rng.uniform(-0.3, 0.3)
        elif profile == "mac_60":
            dt = 16.67 + rng.uniform(-0.5, 0.5)
        elif profile == "win_60_vsync":
            dt = 16.67 + rng.uniform(-0.2, 0.2)
        elif profile == "win_144":
            dt = 6.94 + rng.uniform(-0.3, 0.3)
        elif profile == "win_uncapped_300":
            dt = 3.33 + rng.uniform(-0.8, 0.8)
        elif profile == "lowend_stutter":
            dt = 33.3 + rng.uniform(-3, 3)
            if rng.random() < 0.03:
                dt += rng.uniform(80, 250)  # hitch
        else:
            raise ValueError(profile)
        t += max(1.0, dt)
        yield t


NETWORKS = {
    "LAN":          dict(base=2,   jitter=2,   loss=0.000),
    "good_online":  dict(base=30,  jitter=8,   loss=0.005),
    "far_away":     dict(base=120, jitter=40,  loss=0.02),
    "bad_wifi":     dict(base=60,  jitter=120, loss=0.08),
}

# ------------------------------------------------------------ human input

def human_taps(rng, duration_ms):
    """List of (press_ms, release_ms). Mix of very quick taps, taps and holds."""
    taps = []
    t = 500.0
    while t < duration_ms - 2000:
        r = rng.random()
        if r < 0.25:
            length = rng.uniform(15, 40)     # very fast flick
        elif r < 0.75:
            length = rng.uniform(45, 120)    # normal tap
        else:
            length = rng.uniform(200, 600)   # hold
        taps.append((t, t + length))
        t += length + rng.uniform(150, 700)
    return taps


def is_down(taps, t):
    for p, r in taps:
        if p <= t < r:
            return True
        if p > t:
            break
    return False


# ---------------------------------------------------- client (mirror_view)

def client_packets(taps, profile, rng, version, duration_ms):
    """Packets as (send_ms, seq, buttons_bit0, presscount)."""
    out = []
    timer = 0.0
    seq = 0
    latch = False
    count = 0
    prev_t = 0.0
    press_times = [p for p, _ in taps]
    pi = 0
    for t in frames(profile, rng, duration_ms):
        dt = t - prev_t
        # Input events delivered since the last frame (Godot handles them
        # before _process). Version 2 counts and latches every press.
        while pi < len(press_times) and press_times[pi] <= t:
            if press_times[pi] > prev_t:
                count = (count + 1) & 0xFF
                latch = True
            pi += 1
        prev_t = t
        timer += dt
        if timer >= SEND_INTERVAL:
            timer = 0.0
            down = is_down(taps, t)
            if version >= 2:
                down = down or latch
                latch = False
            seq += 1
            out.append((t, seq, int(down), count))
    return out


def deliver(packets, net, rng):
    """Apply loss, latency and jitter. Returns packets sorted by arrival."""
    arrived = []
    for pkt in packets:
        if rng.random() < net["loss"]:
            continue
        arrival = pkt[0] + net["base"] + rng.uniform(0, net["jitter"])
        arrived.append((arrival,) + pkt)
    arrived.sort(key=lambda a: a[0])
    return arrived


# ------------------------------------------------------ host (online_coop)

def host_run(arrived, host_profile, rng, version, duration_ms):
    """Returns list of (time, pressed) virtual button events the game sees.

    v1: emit an event whenever the received button state changes.
    v2: also compare press counters; presses lost between samples or in
        dropped packets are replayed. Events go through a queue and at most
        one is emitted per host frame, so press/release pairs never collapse
        into the same frame.
    """
    events = []
    st = dict(seq=0, buttons=0, last_ms=0.0, counts=None, queue=[], logical=0)
    ai = 0

    def push(t, pressed):
        if version < 2:
            events.append((t, pressed))
            return
        st["logical"] = int(pressed)
        if not st["queue"] and (not events or events[-1][0] < t):
            events.append((t, pressed))
        else:
            st["queue"].append(pressed)

    for t in frames(host_profile, rng, duration_ms + 2000):
        if st["queue"] and (not events or events[-1][0] < t):
            events.append((t, st["queue"].pop(0)))
        while ai < len(arrived) and arrived[ai][0] <= t:
            _, _, seq, down, count = arrived[ai]
            ai += 1
            if seq <= st["seq"]:
                continue  # old or duplicate
            st["seq"] = seq
            st["last_ms"] = t
            if version >= 2:
                if st["counts"] is not None:
                    missed = (count - st["counts"]) & 0xFF
                    if 0 < missed < 128:
                        n = min(missed, 4)
                        for k in range(n):
                            if st["logical"]:
                                push(t, False)
                            push(t, True)
                            # the last press stays held if the button is down
                            if k < n - 1 or not down:
                                push(t, False)
                st["counts"] = count
                if down != st["logical"]:
                    push(t, bool(down))
            else:
                if down != st["buttons"]:
                    push(t, bool(down))
            st["buttons"] = down
        # 1 s timeout releases held buttons
        held = st["logical"] if version >= 2 else st["buttons"]
        if held and t - st["last_ms"] > INPUT_TIMEOUT:
            st["buttons"] = 0
            push(t, False)
    return events


def score_input(taps, events):
    """Presses arrive in order, so the k-th host press belongs to the k-th
    human press. Missed = presses that never arrived, ghosts = extra ones."""
    presses = [t for t, p in events if p]
    n = min(len(presses), len(taps))
    latencies = [presses[k] - taps[k][0] for k in range(n)]
    missed = max(0, len(taps) - len(presses))
    ghosts = max(0, len(presses) - len(taps))
    if any(l < 0 for l in latencies):
        ghosts += 1  # a host press before its human press means misalignment
    return missed, ghosts, latencies


# ------------------------------------------------------ snapshot pipeline

PARITY_GROUP = 4  # one XOR recovery chunk per 4 data chunks


def snapshot_run(net, rng, duration_ms, rate=20, parity=True):
    """Host sends chunked snapshots; client reassembles like mirror_view.

    With parity, each group of PARITY_GROUP data chunks also gets an XOR
    chunk, so any single lost chunk in a group can be rebuilt. Real bytes
    are XOR'd here to check the recovery maths, not just counted.
    """
    sent = []
    frames_data = {}
    frame = 0
    t = 0.0
    while t < duration_ms:
        frame += 1
        size = int(rng.uniform(3000, 18000))  # compressed bytes
        data = bytes(rng.getrandbits(8) for _ in range(size))
        frames_data[frame] = data
        count = -(-size // CHUNK)
        pkts = [(frame, "d", i, count, size, data[i * CHUNK:(i + 1) * CHUNK]) for i in range(count)]
        if parity:
            for g in range(-(-count // PARITY_GROUP)):
                x = bytearray(CHUNK)
                for i in range(g * PARITY_GROUP, min(count, (g + 1) * PARITY_GROUP)):
                    for j, byte in enumerate(pkts[i][5]):
                        x[j] ^= byte
                pkts.append((frame, "p", g, count, size, bytes(x)))
        for pk in pkts:
            if rng.random() < net["loss"]:
                continue
            sent.append((t + net["base"] + rng.uniform(0, net["jitter"]),) + pk)
        t += 1000.0 / rate
    sent.sort(key=lambda s: s[0])
    chunks = {}
    latest = -1
    shown = []
    for arrival, f, kind, i, count, size, payload in sent:
        if f <= latest:
            continue
        e = chunks.setdefault(f, {"count": count, "size": size, "parts": {}, "parity": {}})
        (e["parts"] if kind == "d" else e["parity"])[i] = payload
        # try to rebuild one missing chunk per group
        for g, px in list(e["parity"].items()):
            idxs = range(g * PARITY_GROUP, min(count, (g + 1) * PARITY_GROUP))
            missing = [k for k in idxs if k not in e["parts"]]
            if len(missing) == 1:
                x = bytearray(px)
                for k in idxs:
                    if k in e["parts"]:
                        for j, byte in enumerate(e["parts"][k]):
                            x[j] ^= byte
                m = missing[0]
                ln = CHUNK if m < count - 1 else size - (count - 1) * CHUNK
                e["parts"][m] = bytes(x[:ln])
        if len(e["parts"]) == e["count"]:
            full = b"".join(e["parts"][k] for k in range(e["count"]))
            assert full == frames_data[f], "rebuilt snapshot is corrupt"
            latest = f
            for k in [k for k in chunks if k <= f]:
                del chunks[k]
            shown.append((arrival, f))
        if len(chunks) > 8:
            del chunks[min(chunks)]
    assert all(b[1] > a[1] for a, b in zip(shown, shown[1:])), "frames shown out of order"
    gaps = [b[0] - a[0] for a, b in zip(shown, shown[1:])]
    return len(shown) / frame, (max(gaps) if gaps else 0), (statistics.mean(gaps) if gaps else 0)


# ------------------------------------------------------------------ report

def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else 0


def main():
    versions = [1, 2] if "--v1" in sys.argv else [2]
    duration = SECONDS * 1000
    clients = ["mac_promotion_120", "mac_60", "win_60_vsync", "win_144", "win_uncapped_300", "lowend_stutter"]
    hosts = ["win_60_vsync", "mac_promotion_120", "lowend_stutter"]
    failures = 0
    for version in versions:
        print(f"\n=== Input protocol v{version} ===")
        print(f"{'client':20} {'host':20} {'network':12} {'taps':>5} {'missed':>7} {'ghost':>6} {'lat avg':>8} {'lat p95':>8}")
        for net_name, net in NETWORKS.items():
            for c in clients:
                for h in hosts:
                    rng = random.Random(zlib.crc32(f"{version}{net_name}{c}{h}".encode()))
                    taps = human_taps(rng, duration)
                    pk = client_packets(taps, c, rng, version, duration)
                    ar = deliver(pk, net, rng)
                    ev = host_run(ar, h, rng, version, duration)
                    missed, ghosts, lat = score_input(taps, ev)
                    flag = ""
                    if version >= 2 and (ghosts > 0 or missed > 0):
                        flag = "  <-- check"
                        failures += 1
                    print(f"{c:20} {h:20} {net_name:12} {len(taps):5} {missed:7} {ghosts:6} {statistics.mean(lat) if lat else 0:8.1f} {pct(lat, 0.95):8.1f}{flag}")

    print("\n=== Screen snapshots (20 per second) ===")
    print(f"{'network':12} {'recovery':9} {'frames shown':>13} {'avg gap ms':>11} {'worst gap ms':>13}")
    for net_name, net in NETWORKS.items():
        for par in (False, True):
            rng = random.Random(zlib.crc32(net_name.encode()))
            shown, worst, avg = snapshot_run(net, rng, 30000, parity=par)
            print(f"{net_name:12} {'on' if par else 'off':9} {shown * 100:12.1f}% {avg:11.1f} {worst:13.1f}")
    print("\nInput scenarios with problems (v2):", failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
