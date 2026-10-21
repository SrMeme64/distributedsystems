#!/bin/bash
# Runbook: JMeter. Usage: run.sh <outdir>   (parameters come from env)
set -u
OUT=$1; mkdir -p "$OUT"; echo $$ > "$OUT/pid"
: "${PROTOCOL:=http}" "${HOST:=presentation-entry}" "${PORT:=80}" "${THREADS:=20}" "${RAMPUP:=5}" \
  "${DURATION:=30}" "${THINK_MS:=0}" "${PATHS:=/}"

esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

PLAN="$OUT/plan.jmx"
{
cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3"><hashTree>
<TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="Resilience lab" enabled="true">
  <boolProp name="TestPlan.functional_mode">false</boolProp>
  <boolProp name="TestPlan.serialize_threadgroups">false</boolProp>
  <elementProp name="TestPlan.user_defined_variables" elementType="Arguments"><collectionProp name="Arguments.arguments"/></elementProp>
</TestPlan><hashTree>
<ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="Users" enabled="true">
  <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
  <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" enabled="true">
    <boolProp name="LoopController.continue_forever">false</boolProp>
    <intProp name="LoopController.loops">-1</intProp>
  </elementProp>
  <stringProp name="ThreadGroup.num_threads">$THREADS</stringProp>
  <stringProp name="ThreadGroup.ramp_time">$RAMPUP</stringProp>
  <boolProp name="ThreadGroup.scheduler">true</boolProp>
  <stringProp name="ThreadGroup.duration">$DURATION</stringProp>
  <stringProp name="ThreadGroup.delay"></stringProp>
  <boolProp name="ThreadGroup.same_user_on_next_iteration">true</boolProp>
</ThreadGroup><hashTree>
XML
if [ "$THINK_MS" -gt 0 ]; then cat <<XML
<ConstantTimer guiclass="ConstantTimerGui" testclass="ConstantTimer" testname="Think time" enabled="true">
  <stringProp name="ConstantTimer.delay">$THINK_MS</stringProp>
</ConstantTimer><hashTree/>
XML
fi
printf '%s\n' "$PATHS" | sed '/^[[:space:]]*$/d' | while read -r P; do
  EP=$(esc "$P")
  cat <<XML
<HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="GET $EP" enabled="true">
  <elementProp name="HTTPsampler.Arguments" elementType="Arguments" guiclass="HTTPArgumentsPanel" testclass="Arguments" enabled="true"><collectionProp name="Arguments.arguments"/></elementProp>
  <stringProp name="HTTPSampler.domain">$HOST</stringProp>
  <stringProp name="HTTPSampler.port">$PORT</stringProp>
  <stringProp name="HTTPSampler.protocol">$PROTOCOL</stringProp>
  <stringProp name="HTTPSampler.path">$EP</stringProp>
  <stringProp name="HTTPSampler.method">GET</stringProp>
  <boolProp name="HTTPSampler.follow_redirects">true</boolProp>
  <boolProp name="HTTPSampler.use_keepalive">true</boolProp>
</HTTPSamplerProxy><hashTree/>
XML
done
echo '</hashTree></hashTree></hashTree></jmeterTestPlan>'
} > "$PLAN"

rm -rf "$OUT/report" "$OUT/results.jtl"
echo "+ jmeter -n -t plan.jmx  (threads=$THREADS ramp=${RAMPUP}s duration=${DURATION}s host=$HOST:$PORT)"
jmeter -n -t "$PLAN" -l "$OUT/results.jtl" -j "$OUT/jmeter.log" -e -o "$OUT/report" 2>&1
