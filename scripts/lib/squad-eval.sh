#!/usr/bin/env bash
# Scoring deductions and cache bonus, in dimension points.
SQUAD_EVAL_ATTEMPT_PENALTY=20
SQUAD_EVAL_LOOP_PENALTY=10
SQUAD_EVAL_TIER_PENALTY=20
SQUAD_EVAL_RECOVERY_PENALTY=30
SQUAD_EVAL_CACHE_BONUS=10
SQUAD_EVAL_VERIFY_POINTS=50
SQUAD_EVAL_MERGED_POINTS=25
SQUAD_EVAL_SCOPE_POINTS=25

squad_eval() {
  local days="$1" run="$2" workspace cutoff file
  local -a files
  cutoff=$(( $(date +%s) - 10#$days * 86400 ))
  workspace="${SQUAD_DEVKIT_PROJECT_ROOT:-$PWD}"
  if [[ -z "${SQUAD_DEVKIT_PROJECT_ROOT:-}" ]]; then
    while [[ "$workspace" != / && ! -d "$workspace/.squad" ]]; do workspace="$(dirname "$workspace")"; done
    [[ -d "$workspace/.squad" ]] || workspace="$PWD"
  fi
  if [[ -n "$run" && ( "$run" == */* || "$run" == . || "$run" == .. ) ]]; then
    echo 'Invalid run name' >&2; return 2
  fi
  files=()
  for file in "$workspace"/.squad/workers/*.status; do
    [[ -f "$file" ]] && files+=("$file")
  done
  if (( ${#files[@]} == 0 )); then echo 'no runs'; return; fi
  awk -v cutoff="$cutoff" -v selected="$run" \
    -v ap="$SQUAD_EVAL_ATTEMPT_PENALTY" -v lp="$SQUAD_EVAL_LOOP_PENALTY" \
    -v tp="$SQUAD_EVAL_TIER_PENALTY" -v rp="$SQUAD_EVAL_RECOVERY_PENALTY" \
    -v cb="$SQUAD_EVAL_CACHE_BONUS" -v vp="$SQUAD_EVAL_VERIFY_POINTS" \
    -v mp="$SQUAD_EVAL_MERGED_POINTS" -v sp="$SQUAD_EVAL_SCOPE_POINTS" '
    FNR == 1 { if (NR > 1) record(); split("", v); filename=FILENAME }
    { p=index($0,"="); if (p) v[substr($0,1,p-1)]=substr($0,p+1) }
    END {
      if (NR) record()
      # Order attempts chronologically so recovery and tier changes are deterministic.
      for (i=2; i<=n; i++) { x=order[i]; j=i-1; while (j && (start[order[j]]>start[x] || (start[order[j]]==start[x] && order[j]>x))) { order[j+1]=order[j]; j-- } order[j+1]=x }
      for (i=1; i<=n; i++) aggregate(order[i])
      for (w in final) {
        r=final[w]; t=tier[r]
        if (duration[r]>=0 && t!="") durations[t,++nd[t]]=duration[r]
        if (token[r]>=0 && t!="") tokens[t,++nt[t]]=token[r]
      }
      for (w in final) {
        r=final[w]; if (selected!="" && !chosen[w]) continue
        t=tier[r]; c=l=tok=rec=d=-1
        if (attempt[r]>0) c=clamp(100-ap*(attempt[r]-1)-(loopok[r]?lp*(loop[r]-1):0)-tp*changes[w])
        if (duration[r]>=0 && t!="") l=curve(duration[r],median(t,nd[t],"d"))
        if (token[r]>=0 && t!="") { tok=curve(token[r],median(t,nt[t],"t")); if (cache[r]>=0.8) tok=clamp(tok+cb) }
        if (gateknown[w]) rec=clamp(100-rp*repeats[w])
        if (deliveryknown[r]) d=delivery[r]
        sum=weight=0
        if (c>=0) {sum+=30*c;weight+=30} if (l>=0) {sum+=20*l;weight+=20}
        if (tok>=0) {sum+=20*tok;weight+=20} if (rec>=0) {sum+=15*rec;weight+=15}
        if (d>=0) {sum+=15*d;weight+=15}
        score[w]=weight ? sum/weight : -1
        line[w]=sprintf("%-20s %-10s %8s %5s %7s %7s %6s %8s %8s %s", w, t==""?"-":t, attempt[r]>0?attempt[r]:"n/a", fmt(score[w]),fmt(c),fmt(l),fmt(tok),fmt(rec),fmt(d), costtext(w))
        output[++count]=w
        if (score[w]>=0 && score[w]<70) below++
        if (l>=0 && l<67) outlier[w]=1
      }
      if (!count) { print "no runs"; exit }
      for (i=2; i<=count; i++) { x=output[i]; j=i-1; while (j && (score[output[j]]>score[x] || (score[output[j]]==score[x] && output[j]>x))) {output[j+1]=output[j];j--} output[j+1]=x }
      print "WORKER               TIER       ATTEMPTS SCORE CONTROL LATENCY TOKENS RECOVERY DELIVERY COST"
      for (i=1;i<=count;i++) print line[output[i]]
      printf "Below threshold (70): %d\n", below
      suggestions=0
      if (fasttotal>=3 && fastfail/fasttotal>=0.5) {print "Suggestion: use balanced for these tasks"; suggestions++}
      for (i=1;i<=count && suggestions<5;i++) {w=output[i]; if (repeatgate[w]!="") {printf "Suggestion: brief should include how to run %s locally\n",repeatgate[w]; suggestions++} }
      for (i=1;i<=count && suggestions<5;i++) {w=output[i]; if (outlier[w]) {printf "Suggestion: split task %s\n",w; suggestions++} }
    }
    function record(   w,r,k,a,b,g,num) {
      if (v["started"] !~ /^[0-9]+$/ || v["started"]+0<cutoff || v["finished"] !~ /^[0-9]+$/ || v["state"]=="running" || v["state"]=="") return
      w=v["worker"]; if (w=="") {w=filename; sub(/^.*\//,"",w); sub(/\.status$/,"",w)}
      r=++n; order[r]=r; worker[r]=w; start[r]=v["started"]+0; stem[r]=filename; sub(/^.*\//,"",stem[r]); sub(/\.status$/,"",stem[r])
      tier[r]=v["model_tier"]; attempt[r]=v["attempt"] ~ /^[1-9][0-9]*$/ ? v["attempt"]+0 : 0
      loopok[r]=(v["loop_iter"] ~ /^[1-9][0-9]*$/ && v["loop_max"] ~ /^[1-9][0-9]*$/); loop[r]=v["loop_iter"]+0
      duration[r]=v["finished"]+0>=start[r] ? v["finished"]-start[r] : -1
      token[r]=-1; cache[r]=-1
      if (v["tokens_in"] ~ /^[0-9]+$/ && v["tokens_cached"] ~ /^[0-9]+$/ && v["tokens_out"] ~ /^[0-9]+$/ && v["tokens_cached"]+0<=v["tokens_in"]+0) { token[r]=v["tokens_in"]-v["tokens_cached"]+v["tokens_out"]; if (v["tokens_in"]+0>0) cache[r]=v["tokens_cached"]/v["tokens_in"] }
      fail[r]=""; known[r]=(v["gates"]!="" || v["verify"]!="")
      num=split(v["gates"],a,","); for (k=1;k<=num;k++) {split(a[k],b,":"); if (b[2]=="fail" || b[2]=="timeout") fail[r]=fail[r] "," b[1] ","}
      if (fail[r]=="" && (v["verify"]=="fail" || v["verify"]=="timeout")) fail[r]=",verify,"
      deliveryknown[r]=("state" in v && "merged" in v && "scope_violation" in v)
      delivery[r]=((v["verify"]=="pass" || (v["verify"]=="" && v["state"]=="completed")) ? vp : 0)+(v["merged"]!="" && v["merged"]!="0" && v["merged"]!="false" ? mp : 0)+(v["scope_violation"]=="" ? sp : 0)
      if (v["cost_status"] ~ /^(reported|estimated)$/ && v["cost_usd"] ~ /^[0-9]+([.][0-9]+)?$/) {costknown[r]=1;cost[r]=v["cost_usd"]+0}
    }
    function aggregate(r,   w,a,k) {
      w=worker[r]; if (stem[r]==selected) chosen[w]=1
      if (!(w in final)) tiersok[w]=1
      if (tier[r]=="") tiersok[w]=0
      if (w in final && tier[r]!="" && tier[final[w]]!="" && tier[r]!=tier[final[w]]) changes[w]++
      if (known[r]) gateknown[w]=1
      if (w in final && known[r] && known[final[w]]) { split(fail[r],a,","); for(k in a) if(a[k]!="" && index(fail[final[w]],"," a[k] ",")) {repeats[w]++; if(repeatgate[w]=="") repeatgate[w]=a[k]} }
      if (attempt[r]==1 && tier[r]=="fast") {fasttotal++; if(fail[r]!="" || (delivery[r]<vp && known[r])) fastfail++}
      if(costknown[r]) {costsum[w]+=cost[r];costcount[w]++} else unknown[w]++
      final[w]=r
    }
    function median(t,n,kind,   a,i,j,x) { for(i=1;i<=n;i++) a[i]=(kind=="d"?durations[t,i]:tokens[t,i]); for(i=2;i<=n;i++) {x=a[i];j=i-1;while(j && a[j]>x){a[j+1]=a[j];j--}a[j+1]=x} return n%2?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2 }
    function curve(x,m) {if(m==0) return x==0?100:0; return clamp(100*(4-x/m)/3)}
    function clamp(x) {return x<0?0:x>100?100:x}
    function fmt(x) {return x<0?"n/a":sprintf("%.0f",x)}
    function costtext(w,   s) {s=costcount[w]?sprintf("$%.4f",costsum[w]):"unknown"; if(costcount[w] && unknown[w]) s=s sprintf(" (+%d unknown)",unknown[w]); return s}
  ' "${files[@]}"
}
