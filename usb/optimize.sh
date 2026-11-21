#!/system/bin/sh
# GBOS System, Performance, RAM and CPU Optimization
# Configured for PC hardware running gbOS86
#   optimize.sh               gbos_optimize (gbos.rc), once after boot_completed
#   optimize.sh cpu MODE      only gbos_cpu_power MODE (gbos.rc runs "cpu balanced" at boot_completed)

# --- cpu power (tested by tools/test_power.sh) ---
# hook.sh puts every CPU at governor/EPP "performance" while Android boots. At boot_completed Google's powertool sets its own default
# (vendor powertool.rc, "set-default-power-preference": governor powersave + EPP balance_performance, logged by powertool) and the
# power HAL changes it later through vendor.powerhal.governor/epp. Until 2026-11-17 this script forced "performance" back on every
# machine; meant for software rendering, it also pinned laptops with a hardware GPU at their highest clocks (intel_pstate's
# "performance" policy raises the HWP minimum to the maximum): battery and heat (HANDOFF.md 2026-11-17).
#   balanced     gbos.rc, at boot_completed and just before powertool (system rc actions run before vendor ones), so powertool has
#                the last word as on Google's own machines. Undoes only the boot-time "performance": EPP drivers (intel_pstate,
#                amd-pstate-epp in active mode) get governor powersave + EPP balance_performance; the others (acpi-cpufreq,
#                intel_cpufreq / amd-pstate in passive mode) get schedutil (or ondemand), because "powersave" pins them at their
#                lowest frequency.
#   guard        after powertool, hardware GPU: only that last case, in case powertool picked "powersave" on such a driver.
#   performance  after powertool: software rendering (the CPU draws every frame) or CPU_PERFORMANCE=1 in gbos.cfg
#                (hook.sh sets ro.gbos.cpu_performance=1 for both).
# Writes one summary line to the kernel log (kmsg.log). CPUFREQ= and KMSG= are only for tests.
gbos_cpu_power() {
    _n=0; _all=
    for _p in "${CPUFREQ:-/sys/devices/system/cpu/cpufreq}"/policy*; do
        [ -f "$_p/scaling_governor" ] || continue
        _n=$((_n + 1))
        _gov=$(cat "$_p/scaling_governor" 2>/dev/null)
        if [ "$1" = performance ]; then
            echo performance > "$_p/scaling_governor" 2>/dev/null
            [ -f "$_p/energy_performance_preference" ] && echo performance > "$_p/energy_performance_preference" 2>/dev/null
        elif [ -f "$_p/energy_performance_preference" ]; then
            if [ "$1" = balanced ]; then
                # The governor first: intel_pstate refuses any other EPP (EBUSY) while the policy is "performance".
                [ "$_gov" = performance ] && echo powersave > "$_p/scaling_governor" 2>/dev/null
                [ "$(cat "$_p/energy_performance_preference" 2>/dev/null)" = performance ] \
                    && echo balance_performance > "$_p/energy_performance_preference" 2>/dev/null
            fi
        else
            case "$1:$_gov" in
                balanced:performance|balanced:powersave|guard:powersave)
                    for _g in schedutil ondemand; do
                        grep -qw "$_g" "$_p/scaling_available_governors" 2>/dev/null \
                            && { echo "$_g" > "$_p/scaling_governor" 2>/dev/null; break; }
                    done;;
            esac
        fi
        _epp=-; [ -f "$_p/energy_performance_preference" ] && _epp=$(cat "$_p/energy_performance_preference" 2>/dev/null)
        _all="$_all
$(cat "$_p/scaling_driver" 2>/dev/null) $(cat "$_p/scaling_governor" 2>/dev/null)/$_epp"
    done
    # One "driver governor/EPP" per distinct setting (all policies alike: one), e.g. "intel_pstate powersave/balance_performance".
    _all=$(echo "$_all" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    echo "gbos-cpu: $1: $_n cpufreq policies: ${_all:-none}" > "${KMSG:-/dev/kmsg}" 2>/dev/null
}
# --- end cpu power ---
if [ "$1" = cpu ]; then
    gbos_cpu_power "${2:-balanced}"
    exit 0
fi

sleep 4

# ==============================================================================
# 1. HARDWARE & CPU PERFORMANCE
# ==============================================================================
# CPU governor/EPP: see gbos_cpu_power above. powertool's boot-time exec sets vendor.powertool.init=1 when it is done; wait for it
# (at most 15 s more) so that what follows is applied after it, not overwritten by it.
_w=0
while [ "$(getprop vendor.powertool.init)" != 1 ] && [ $_w -lt 15 ]; do sleep 1; _w=$((_w + 1)); done
if [ "$(getprop ro.gbos.cpu_performance)" = 1 ]; then
    gbos_cpu_power performance
else
    gbos_cpu_power guard
fi

# Disable USB autosuspend on mice/keyboards so there is no wake latency
for d in /sys/bus/usb/devices/*/power/control; do
    echo on > "$d" 2>/dev/null
done

# Ensure all cpusets are valid for the actual online CPU count (e.g. 0-3 on a 4-thread CPU)
# Google's powerhint assumes 8 cores (4-7) which fails with EINVAL and starves background tasks
NUM_CPUS=$(nproc 2>/dev/null || echo 4)
VALID_CPUS="0-$((NUM_CPUS - 1))"
for cs in /dev/cpuset/*/cpus /dev/cpuset/cpus; do
    echo "$VALID_CPUS" > "$cs" 2>/dev/null
done
setprop vendor.sys_tuner.disable_cpuset_config true

# Stop OEM proprietary touchpad inhibitor if it is spinning in a 1-second busy loop
stop touchpad-inhibitor 2>/dev/null

# Suppress drmhwc 60 FPS gamma log spam that causes SurfaceFlinger frame pacing jitter
setprop log.tag.drmhwc WARN
setprop persist.log.tag.drmhwc WARN

# ==============================================================================
# 2. DISABLE WINDOW BLURS & STREAMLINE ANIMATIONS
# ==============================================================================
# Only while the CPU composites (hook.sh sets ro.gbos.software_rendering=1 then). With a hardware GPU the animations and blur stay at
# Google's defaults: forcing them off on every boot (builds from 2026-11-04) made the UI look broken and overrode the user's settings.
if [ "$(getprop ro.gbos.software_rendering)" = 1 ]; then
    settings put global disable_window_blurs 1 2>/dev/null
    cmd window disable-blur 1 2>/dev/null
    setprop persist.sys.sf.disable_blurs 1 2>/dev/null
    settings put global window_animation_scale 0 2>/dev/null
    settings put global transition_animation_scale 0 2>/dev/null
    settings put global animator_duration_scale 0 2>/dev/null
elif [ "$(getprop persist.gbos.anim_restored)" != 1 ]; then
    # One-time repair for installs that already got the values above written into /data by the 2026-11-04 builds.
    settings put global disable_window_blurs 0 2>/dev/null
    cmd window disable-blur 0 2>/dev/null
    setprop persist.sys.sf.disable_blurs 0 2>/dev/null
    settings put global window_animation_scale 1 2>/dev/null
    settings put global transition_animation_scale 1 2>/dev/null
    settings put global animator_duration_scale 1 2>/dev/null
    setprop persist.gbos.anim_restored 1 2>/dev/null
fi

# ==============================================================================
# 3. DISABLE SWAP (Protects storage from wear, latency spikes, and stalls)
# ==============================================================================
swapoff -a 2>/dev/null
if [ -e /sys/block/zram0/reset ]; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null
fi
rm -rf /data/per_boot/zram_swap /data/vendor/swap 2>/dev/null

sysctl -w vm.swappiness=0 2>/dev/null
sysctl -w vm.dirty_background_ratio=5 2>/dev/null
sysctl -w vm.dirty_ratio=10 2>/dev/null
sysctl -w vm.vfs_cache_pressure=100 2>/dev/null

# ==============================================================================
# 4. OPTIMIZE HEADLESS USER 0 (Frees 2.5 - 3.0 GB of RAM)
# User 0 is headless (system only); User 10 is the interactive human user.
# Disable duplicate client apps & Google services in User 0 ONLY.
# User 10 remains 100% untouched so the user can run all apps normally.
# NOT com.android.vending: Play Store in user 10 binds its MultiUserCoordinatorService in user 0 before every download, and with
# the user-0 copy disabled every update and "system services" update stayed "Pending" (HANDOFF.md 2026-11-17).
# ==============================================================================
# Installs that ran this script from 2026-11-04 on keep the user-0 disable in /data, so undo it (no-op when already enabled).
pm enable --user 0 com.android.vending >/dev/null 2>&1
USER0_BLOAT="
com.google.android.apps.messaging
com.google.android.apps.photos
com.google.android.youtube
com.google.android.keep
com.google.android.apps.recorder
com.google.android.apps.bard
com.google.android.retaildemo
com.google.android.federatedcompute
com.google.android.ondevicepersonalization.services
com.google.android.aicore
com.google.android.marvin.talkback
com.google.android.googlequicksearchbox
com.android.chrome
"
for pkg in $USER0_BLOAT; do
    am force-stop --user 0 "$pkg" 2>/dev/null
    pm disable-user --user 0 "$pkg" 2>/dev/null
done

# ==============================================================================
# 5. DISABLE GLOBAL SYSTEM BLOATWARE & TELEMETRY (For All Users)
# Things that serve zero purpose on a laptop PC (retail demo, telemetry trackers)
# ==============================================================================
GLOBAL_BLOAT="
com.google.android.retaildemo
com.google.android.federatedcompute
com.google.android.ondevicepersonalization.services
com.google.android.snapshotservice
com.android.simappdialog
com.android.emergency
com.android.eyedropper
"
for pkg in $GLOBAL_BLOAT; do
    am force-stop "$pkg" 2>/dev/null
    pm disable-user --user 10 "$pkg" 2>/dev/null
done

# ==============================================================================
# 6. SUPPORT USER BACKGROUND PROCESSES & MULTITASKING (User 10)
# ==============================================================================
setprop persist.sys.max_cached_processes 64
setprop ro.sys.fw.bg_apps_limit 64
setprop sys.use_fifo_ui 1

pm grant --user 10 com.google.ambient.streaming android.permission.ACCESS_LOCAL_NETWORK 2>/dev/null

sync
