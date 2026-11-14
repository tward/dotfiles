#!/bin/sh
# waybar custom/memory: icon color class plus a tooltip that breaks RAM down by
# owner. Prints one JSON object per run; waybar polls it (see config.jsonc).
#
# Why not waybar's built-in memory module: it reports MemTotal - MemAvailable,
# and on the Strix Halo desktop that counts the amdgpu TTM page pool as used.
# The pool is freed GPU memory the kernel keeps for reuse and hands back under
# pressure, but it sits in no /proc/meminfo bucket, so MemAvailable misses it.
# After a large model unloads, the built-in module reads "critical" on an idle
# machine. Here the color follows memory that is really in use: total minus
# MemAvailable minus the pool.
#
# The pool's true size is root-only (debugfs), so it is ESTIMATED as the
# residual: MemTotal minus every bucket readable without root. Anything else
# the kernel leaves unaccounted lands in the same number, hence the "~" in the
# tooltip. One comparison on 2026-11-14: estimate 29.2 GiB, debugfs 29.6 GiB
# read some minutes earlier.
#
# Without an amdgpu card (the laptop) there is no TTM pool to speak of: the
# residual is shown as "Other" and stays counted as in use.

# Live GPU memory (GTT) in bytes, summed over amdgpu cards. The cardN index
# changes between boots, so glob for it.
gtt=0
has_gpu=0
for f in /sys/class/drm/card*/device/mem_info_gtt_used; do
    [ -r "$f" ] || continue
    read -r n < "$f" || continue
    gtt=$((gtt + n))
    has_gpu=1
done

# RAM held by zram's compressed store in bytes (mm_stat field 3,
# mem_used_total). Not in any meminfo bucket either.
zram=0
for f in /sys/block/zram*/mm_stat; do
    [ -r "$f" ] || continue
    read -r _ _ n _ < "$f" || continue
    zram=$((zram + n))
done

exec awk -v gtt_bytes="$gtt" -v zram_bytes="$zram" -v has_gpu="$has_gpu" '
function gib(kb) { return sprintf("%.1fG", kb / 1048576) }

# One aligned tooltip line. Optional rows vanish when they would print 0.0G.
function row(label, kb, optional, prefix, note) {
    if (optional && kb / 1048576 < 0.05) return ""
    return sprintf("%-10s %7s%s\\n", label, prefix gib(kb), note)
}

{ v[$1] = $2 }    # /proc/meminfo; every value is in kB

END {
    total = v["MemTotal:"]
    gtt   = gtt_bytes / 1024
    zram  = zram_bytes / 1024

    # KernelStack is left out: stacks are vmalloc-backed on x86-64, so
    # VmallocUsed already covers them.
    kern  = v["SUnreclaim:"] + v["PageTables:"] + v["Percpu:"] + v["VmallocUsed:"]
    # Cached includes Shmem, which cannot be dropped; move it out.
    cache = v["Buffers:"] + v["Cached:"] - v["Shmem:"] + v["SReclaimable:"]

    resid = total - (v["MemFree:"] + cache + v["AnonPages:"] + v["Shmem:"] + kern + gtt + zram)
    if (resid < 0) resid = 0
    pool  = has_gpu ? resid : 0
    other = has_gpu ? 0 : resid

    inuse = total - v["MemAvailable:"] - pool
    # What MemAvailable withholds from free + cache (zone watermarks and the
    # slice of cache the kernel assumes it cannot drop).
    reserve = inuse - (v["AnonPages:"] + v["Shmem:"] + kern + gtt + zram + other)
    pct = int(100 * inuse / total)

    # Same thresholds as the cpu module "states" in config.jsonc.
    cls = ""
    if (pct >= 76) cls = "critical"
    else if (pct >= 65) cls = "high"
    else if (pct >= 50) cls = "warning"
    else if (pct >= 25) cls = "moderate"

    # Share of the last 10 s that some task stalled waiting for memory.
    psi = ""
    while ((getline line < "/proc/pressure/memory") > 0)
        if (line ~ /^some/) { split(line, p, /[ =]/); psi = p[3] }

    tip = sprintf("RAM %d%% · %s of %s in use\\n\\n", pct, gib(inuse), gib(total))
    tip = tip row("Apps", v["AnonPages:"])
    tip = tip row("GPU live", gtt, 1)
    tip = tip row("Kernel", kern)
    tip = tip row("Shared", v["Shmem:"])
    tip = tip row("zram", zram, 1)
    tip = tip row("Other", other, 1)
    tip = tip row("Reserve", reserve, 1)
    tip = tip "\\n"
    tip = tip row("TTM pool", pool, 1, "~", "  purgeable")
    tip = tip row("Cache", cache, 0, "", "  purgeable")
    tip = tip row("Free", v["MemFree:"])
    if (psi != "") tip = tip sprintf("\\nPressure %s%%\\n", psi)
    sub(/(\\n)+$/, "", tip)

    printf "{\"text\": \"\", \"tooltip\": \"%s\", ", tip
    if (cls != "") printf "\"class\": \"%s\", ", cls
    printf "\"percentage\": %d}\n", pct
}
' /proc/meminfo
