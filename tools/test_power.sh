#!/bin/sh
# Shell unit test of the CPU power / temperature pieces (HANDOFF.md 2026-11-17), against fake sysfs trees (no root, nothing touches the machine):
#   gbos_long_modaliases (usb/hwdetect.sh)   modules that busybox modprobe cannot match on a long modalias (x86_pkg_temp_thermal, dell_laptop)
#   gbos_cpu_power       (usb/optimize.sh)   governor/EPP hand-back to Google's powertool, software-rendering "performance"
#   gbos_thermal_config  (usb/hook.sh)       the thermal HAL config, only with an x86_pkg_temp zone
# plus the packaging and gbos.rc wiring around them.
#   sh tools/test_power.sh        (also: busybox sh tools/test_power.sh)
# Each function is pulled out of its script between its marker comments, so what is tested is what boots. Prints POWER_TEST_PASS.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
U=$HERE/../usb
T=$(mktemp -d "${TMPDIR:-/tmp}/power.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "FAIL $1"; }
block() { # file start-marker end-marker
  sed -n "/^# --- $2/,/^# --- $3 ---/p" "$1" > "$T/block.sh"
  [ -s "$T/block.sh" ] || { echo "FAIL: marker block '$2' not found in $1"; exit 1; }
  . "$T/block.sh"
}

# ---------------------------------------------------------------- long modaliases
block "$U/hwdetect.sh" "long modaliases" "end long modaliases"
# Alias lines as depmod writes them for kernel 6.18.21-gbos-whl (usb/modules/.../modules.alias).
cat > "$T/modules.alias" <<'EOF'
alias cpu:type:x86,ven0000fam*mod*:feature:*01C6* x86_pkg_temp_thermal
alias cpu:type:x86,ven0000fam0006mod00BA:feature:* intel_rapl_common
alias cpu:type:x86,ven0000fam0006mod008C:feature:* intel_rapl_common
alias dmi:*:[bs]vnD[Ee][Ll][Ll]*:* dcdbas
alias dmi*:svn*DellInc.*:ct*10*: dell_laptop
alias dmi*:svn*DellInc.*:ct*31*: dell_laptop
alias pci:v00008086d0000A0E8sv*sd*bc*sc*i* intel_lpss_pci
alias acpi*:INT3400:* int3400_thermal
EOF
MODALIASES_FILE=$T/modules.alias
feat=",0000"; i=1; while [ $i -lt 120 ]; do feat="$feat,$(printf '%04X' $i)"; i=$((i+1)); done
CPU_RPL="cpu:type:x86,ven0000fam0006mod00BA:feature:$feat,01C6,01C7,"   # Raptor Lake-P, ~650 characters
CPU_NOPTS="cpu:type:x86,ven0000fam0006mod008C:feature:$feat,"           # Tiger Lake without package thermal status (test only)
DMI_DELL="dmi:bvnDellInc.:bvr1.31.0:bd06/05/2024:br1.31:svnDellInc.:pnVostro3400:pvr:rvnDellInc.:rn0ABCDE:rvrA00:cvnDellInc.:ct10:cvr:sku0A20:"
PCI="pci:v00008086d0000A0E8sv00001179sd00000001bc0Csc80i00"
ACPI="acpi:INT3400:"
got=$(printf '%s\n' "$CPU_RPL" "$DMI_DELL" "$PCI" "$ACPI" | gbos_long_modaliases | tr '\n' ' ')
[ "$got" = "dcdbas dell_laptop intel_rapl_common x86_pkg_temp_thermal " ] && ok "long CPU + DMI modaliases -> $got" || bad "long CPU + DMI modaliases: got '$got'"
got=$(printf '%s\n' "$CPU_NOPTS" | gbos_long_modaliases | tr '\n' ' ')
[ "$got" = "intel_rapl_common " ] && ok "CPU without feature 01C6 -> $got(no x86_pkg_temp_thermal)" || bad "CPU without 01C6: got '$got'"
got=$(printf '%s\n' "$PCI" "$ACPI" | gbos_long_modaliases)
[ -z "$got" ] && ok "short modaliases are left to busybox modprobe" || bad "short modaliases: got '$got'"
[ ${#PCI} -le 55 ] && [ ${#CPU_RPL} -gt 55 ] && ok "fixture lengths (pci ${#PCI}, cpu ${#CPU_RPL} characters)" || bad "fixture lengths"
grep -q 'gbos_long_modaliases' "$U/hwdetect.sh" && grep -q 'modprobe -a -q -b \$GBOS_LONG_MODS' "$U/hwdetect.sh" \
  && ok "gbos_coldplug_pass loads them by name, blacklist applied (-b)" || bad "gbos_coldplug_pass does not use gbos_long_modaliases"
# gbos_hwdetect runs "gbos_coldplug && gbos_wait_devices": a trailing "[ -n ... ] && log" would return 1 when nothing matched.
for fn in gbos_coldplug gbos_coldplug_pass; do
  sed -n "/^$fn() {/,/^}/p" "$U/hwdetect.sh" | tail -n 2 | head -n 1 | grep -q '^  return 0$' \
    && ok "$fn ends with return 0" || bad "$fn does not end with return 0 (gbos_wait_devices would be skipped)"
done

# ---------------------------------------------------------------- CPU governor / EPP
block "$U/optimize.sh" "cpu power" "end cpu power"
KMSG=$T/kmsg
# fake cpufreq: $1 = driver, $2 = governor, $3 = EPP ("-" = the driver has no EPP), $4 = available governors, $5 = number of policies
mkcpu() {
  rm -rf "$T/cpufreq" "$KMSG"; i=0
  while [ $i -lt ${5:-4} ]; do
    p=$T/cpufreq/policy$i; mkdir -p "$p"
    echo "$1" > "$p/scaling_driver"; echo "$2" > "$p/scaling_governor"; echo "$4" > "$p/scaling_available_governors"
    [ "$3" = - ] || echo "$3" > "$p/energy_performance_preference"
    i=$((i+1))
  done
  CPUFREQ=$T/cpufreq
}
state() { # every policy's governor/EPP, de-duplicated
  for p in "$T"/cpufreq/policy*; do echo "$(cat "$p/scaling_governor")/$(cat "$p/energy_performance_preference" 2>/dev/null || echo -)"; done | sort -u | tr '\n' ' '
}
cpu() { # name mode driver gov epp avail expected
  mkcpu "$3" "$4" "$5" "$6"
  gbos_cpu_power "$2"
  got=$(state)
  if [ "$got" = "$7 " ]; then ok "$1: $2 -> $got"; else bad "$1: $2: wanted '$7', got '$got'"; fi
}
PST="performance powersave"; ACPIG="conservative ondemand userspace powersave performance schedutil"
cpu "intel_pstate after boot"       balanced    intel_pstate performance performance         "$PST"   "powersave/balance_performance"
cpu "intel_pstate already balanced" balanced    intel_pstate powersave   balance_power       "$PST"   "powersave/balance_power"
cpu "intel_pstate, EPP only"        balanced    intel_pstate powersave   performance         "$PST"   "powersave/balance_performance"
cpu "intel_pstate after powertool"  guard       intel_pstate powersave   balance_performance "$PST"   "powersave/balance_performance"
cpu "intel_pstate, user chose perf" guard       intel_pstate performance performance         "$PST"   "performance/performance"
cpu "software rendering"            performance intel_pstate powersave   balance_performance "$PST"   "performance/performance"
cpu "amd-pstate-epp after boot"     balanced    amd-pstate-epp performance performance       "$PST"   "powersave/balance_performance"
cpu "acpi-cpufreq after boot"       balanced    acpi-cpufreq performance -                   "$ACPIG" "schedutil/-"
cpu "acpi-cpufreq, powersave"       guard       acpi-cpufreq powersave   -                   "$ACPIG" "schedutil/-"
cpu "acpi-cpufreq, performance"     guard       acpi-cpufreq performance -                   "$ACPIG" "performance/-"
cpu "acpi-cpufreq, no schedutil"    balanced    acpi-cpufreq performance -                   "ondemand powersave performance" "ondemand/-"
cpu "intel_cpufreq (passive)"       balanced    intel_cpufreq powersave  -                   "$ACPIG" "schedutil/-"
cpu "acpi-cpufreq, software"        performance acpi-cpufreq schedutil   -                   "$ACPIG" "performance/-"
mkcpu intel_pstate performance performance "$PST" 16; gbos_cpu_power balanced
grep -q '^gbos-cpu: balanced: 16 cpufreq policies: intel_pstate powersave/balance_performance$' "$KMSG" \
  && ok "kernel log line: $(cat "$KMSG")" || bad "kernel log line: '$(cat "$KMSG" 2>/dev/null)'"
# hybrid CPU with one policy left alone (EPP changed by someone else): both settings named
mkcpu intel_pstate performance performance "$PST" 3; echo power > "$T/cpufreq/policy2/energy_performance_preference"; echo powersave > "$T/cpufreq/policy2/scaling_governor"
gbos_cpu_power balanced
grep -q '^gbos-cpu: balanced: 3 cpufreq policies: intel_pstate powersave/balance_performance, intel_pstate powersave/power$' "$KMSG" \
  && ok "kernel log line, mixed policies: $(cat "$KMSG")" || bad "kernel log line, mixed: '$(cat "$KMSG" 2>/dev/null)'"
rm -rf "$T/cpufreq"; mkdir -p "$T/cpufreq"; gbos_cpu_power balanced
grep -q '^gbos-cpu: balanced: 0 cpufreq policies' "$KMSG" && ok "no cpufreq at all: nothing written, logged" || bad "no cpufreq: '$(cat "$KMSG")'"

# ---------------------------------------------------------------- thermal HAL config
block "$U/hook.sh" "thermal HAL config" "end thermal HAL config"
mktz() { rm -rf "$T/thermal"; i=0; for t in "$@"; do mkdir -p "$T/thermal/thermal_zone$i"; echo "$t" > "$T/thermal/thermal_zone$i/type"; i=$((i+1)); done; THERMAL=$T/thermal; }
mktz acpitz acpitz iwlwifi_1 x86_pkg_temp
if gbos_thermal_config > "$T/tc.json"; then
  if command -v python3 >/dev/null 2>&1; then
    chk=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["Sensors"]; assert len(s)==1, s; s=s[0]
assert s["Name"]=="x86_pkg_temp" and s["Type"]=="CPU" and s["Multiplier"]==0.001 and s["Monitor"] is False, s
assert s["HotThreshold"]==["NAN"]*7, s["HotThreshold"]; print("valid JSON, 1 sensor, 7 NAN thresholds")' "$T/tc.json" 2>&1) \
      && ok "x86_pkg_temp zone present: $chk" || bad "thermal config: $chk"
  else
    grep -q '"Name": "x86_pkg_temp"' "$T/tc.json" && ok "x86_pkg_temp zone present: config written (no python3 for the JSON check)" || bad "thermal config content"
  fi
else bad "x86_pkg_temp zone present but no config"; fi
mktz acpitz iwlwifi_1
gbos_thermal_config > "$T/tc.json" && bad "no x86_pkg_temp zone, but a config was written" || { [ -s "$T/tc.json" ] && bad "output without the zone" || ok "no x86_pkg_temp zone (AMD, old kernel): nothing, Google's file kept"; }
rm -rf "$T/thermal"; mkdir -p "$T/thermal"
gbos_thermal_config > /dev/null && bad "no thermal zones at all, but a config" || ok "no thermal zones at all: nothing"

# ---------------------------------------------------------------- wiring
if grep -q 'cpu[0-9]/cpufreq/scaling_governor performance' "$U/hook.sh"; then bad "gbos.rc still writes performance at boot_completed"; else ok "gbos.rc no longer forces performance at boot_completed"; fi
grep -q '^    \$CPURC$' "$U/hook.sh" && grep -q 'CPURC="exec u:r:shell:s0 root root -- /system/bin/sh /postinstall/gbos/optimize.sh cpu balanced"' "$U/hook.sh" \
  && ok "gbos.rc: hand-back is an exec with a seclabel at boot_completed" || bad "gbos.rc: CPURC wiring missing"
grep -q 'echo "ro.gbos.cpu_performance=1"' "$U/hook.sh" && grep -q 'getprop ro.gbos.cpu_performance' "$U/optimize.sh" \
  && ok "ro.gbos.cpu_performance: written by hook.sh, read by optimize.sh" || bad "ro.gbos.cpu_performance wiring"
grep -q '^    start gbos_powerdiag$' "$U/hook.sh" && grep -q '^service gbos_powerdiag ' "$U/hook.sh" && ok "gbos_powerdiag defined and started" || bad "gbos_powerdiag wiring"
if sed -n '/^service gbos_powerdiag /p' "$U/hook.sh" | sed 's/boot-\$N//' | grep -q '[$`\\]'; then bad "gbos_powerdiag: \$, \` or \\ in the rc line besides boot-\$N"; else ok "gbos_powerdiag: no runtime shell variable in the rc line"; fi
for f in "$U/install.sh:^FILES=" "$HERE/deploy_stick.sh:^for f in hook.sh" "$HERE/make_gbos86_image.sh:^for f in hook.sh" "$HERE/install_dualboot.sh:^for f in hook.sh"; do
  file=${f%%:*}; pat=${f#*:}
  grep "$pat" "$file" | grep -qw optimize.sh && ok "optimize.sh shipped by ${file##*/}" || bad "optimize.sh missing from ${file##*/} ($pat)"
done

echo "$n checks, $fails failed"
[ $fails = 0 ] && echo POWER_TEST_PASS || exit 1
