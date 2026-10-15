# Size-only export figures and local slopes; no timing input is read.
# uv run --with matplotlib==3.10.7 --with numpy==2.3.4 python bench/rendering-design/stress-report.py
import csv,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
H=Path(__file__).resolve().parent
D=json.loads((H/'results/stress-report-data.json').read_text())
rows=D['rows'];out=H/'results/stress/graphs';out.mkdir(parents=True,exist_ok=True)
modes=['tea','direct','vanilla','partial','static','local','cells','solid']
names=['Today TEA','Today direct','Vanilla','A: partial evaluation','B: static reactivity','C: local reducers','D: explicit cells','Solid 2']
colors=['#465363','#d45130','#12845b','#2675cc','#8a4eae','#b88500','#c34c8b','#36a0ae']
families=['mixed','list','form','tabs','nested','thread','cluster','table','modal','filter','summary']
plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,'figure.dpi':150,'svg.hashsalt':'rendering-design-stress-172'})
def draw(ax,family,log=True):
 for mode,name,color in zip(modes,names,colors):
  rs=[r for r in rows if r['family']==family and r['mode']==mode]
  if not rs:continue
  ns=sorted(set(r['n'] for r in rs));ys=[[r['brotli']/1000 for r in rs if r['n']==n] for n in ns]
  ax.plot(ns,[np.median(y) for y in ys],marker='o',ms=3,lw=1.5,color=color,label=name)
  ax.fill_between(ns,[min(y) for y in ys],[max(y) for y in ys],color=color,alpha=.13)
 ax.axhline(512,color='#909aad',linestyle='--',linewidth=1,label='512 kB target')
 if log:ax.set_xscale('log',base=2)
 ax.set_ylim(bottom=0);ax.set_xlabel('Component instances (N)'+(' · log₂' if log else ''));ax.set_ylabel('Rendering response · brotli kB');ax.set_title(family.capitalize());ax.grid(alpha=.15)
def save(fig,name):
 fig.savefig(out/(name+'.png'));fig.savefig(out/(name+'.svg'),metadata={'Date':None});plt.close(fig)
for log in [True,False]:
 fig,ax=plt.subplots(figsize=(11,6));draw(ax,'mixed',log);ax.legend(ncol=3,fontsize=8);fig.suptitle('Measured rendering growth toward 512 kB brotli',weight='bold');fig.tight_layout();save(fig,'mixed-growth'+('' if log else '-linear'))
fig,axes=plt.subplots(5,2,figsize=(13,19))
for ax,family in zip(axes.flat,families[1:]):draw(ax,family)
handles,labels=axes.flat[0].get_legend_handles_labels();fig.legend(handles,labels,loc='upper center',ncol=4,fontsize=9);fig.suptitle('Family stress curves · measured points, no extrapolation',y=.998,weight='bold');fig.tight_layout(rect=[0,0,1,.955]);save(fig,'family-growth')
fig,ax=plt.subplots(figsize=(11,5))
for mode,name,color in zip(modes,names,colors):
 rs=sorted([r for r in rows if r['family']=='mixed' and r['mode']==mode and r['seed']==17],key=lambda r:r['n'])
 if len(rs)<2:continue
 ax.plot([r['n'] for r in rs[1:]],[(b['brotli']-a['brotli'])/(b['n']-a['n']) for a,b in zip(rs,rs[1:])],marker='o',ms=3,color=color,label=name)
ax.set_xscale('log',base=2);ax.set_xlabel('Component count at end of interval (N)');ax.set_ylabel('Additional brotli bytes / component');ax.set_title('Mixed app: local growth rates, seed 17');ax.grid(alpha=.15);ax.legend(ncol=3,fontsize=8);fig.tight_layout();save(fig,'marginal-growth')
fits=[];crossings=[]
for family in families:
 for mode in modes:
  rs=sorted([r for r in rows if r['family']==family and r['mode']==mode and r['seed']==17],key=lambda r:r['n'])
  if not rs:continue
  hit=next((r for r in rs if r['brotli']>=D['target']),None)
  crossings.append({'family':family,'mode':mode,'crossing_n':hit['n'] if hit else None,'crossing_brotli':hit['brotli'] if hit else None,'last_n':rs[-1]['n'],'last_brotli':rs[-1]['brotli'],'compiler_limited':any(s['family']==family and s['mode']==mode for s in D.get('stopped',[]))})
  for label,lo,hi in [('small',1,32),('medium',32,512),('large',512,float('inf'))]:
   points=[r for r in rs if lo<=r['n']<=hi]
   if len(points)<3:continue
   x=np.array([r['n'] for r in points]);y=np.array([r['brotli'] for r in points]);slope,intercept=np.polyfit(x,y,1)
   fits.append({'family':family,'mode':mode,'range':label,'min_n':int(min(x)),'max_n':int(max(x)),'points':len(points),'slope':float(slope),'intercept':float(intercept),'rmse':float(np.sqrt(np.mean((y-(intercept+slope*x))**2)))})
(H/'results/stress/fits.json').write_text(json.dumps(fits,indent=2)+'\n')
(H/'results/stress/crossings.json').write_text(json.dumps(crossings,indent=2)+'\n')
with (H/'results/stress/sizes.csv').open('w') as f:
 keys=['family','n','seed','mode','raw','brotli','gzip','runtime','app_increment','full_brotli','sha256'];w=csv.DictWriter(f,fieldnames=keys,extrasaction='ignore',lineterminator='\n');w.writeheader();w.writerows(rows)
lines=['# Measured crossings of 512 kB brotli','','A missing crossing is incomplete or compiler-limited, not an estimate. See stopped.jsonl and issue #203 for compiler failures. N≤32: three seeds in the plotted bands; stress points: seed 17. Table below uses seed 17 throughout.','','| Family | Strategy | First crossing N | Crossing bytes | Last measured N | Last bytes |','|---|---|---:|---:|---:|---:|']
for r in crossings:lines.append('| '+' | '.join(str(r[k]) if r[k] is not None else '—' for k in ['family','mode','crossing_n','crossing_brotli','last_n','last_brotli'])+' |')
(H/'results/stress/crossings.md').write_text('\n'.join(lines)+'\n')
for file in out.glob('*.svg'):file.write_text('\n'.join(line.rstrip() for line in file.read_text().splitlines()).rstrip()+'\n')
print(f"Size-only figures: {len(rows)} measured bundles, {sum(r['crossing_n'] is not None for r in crossings)}/{len(crossings)} crossings")
