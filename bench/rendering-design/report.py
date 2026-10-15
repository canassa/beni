# Run: uv run --with matplotlib==3.10.7 --with numpy==2.3.4 python bench/rendering-design/report.py
import json,csv
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
H=Path(__file__).resolve().parent
rows=json.loads((H/'results/sizes.json').read_text())['observations']+json.loads((H/'results/solid-sizes.json').read_text())['observations']
modes=['tea','direct','vanilla','partial','static','local','cells','solid']
labels=['Today TEA','Today direct','Vanilla','A: partial evaluation','B: static reactivity','C: local reducers','D: explicit cells','Solid 2']
colors=['#444444','#c45732','#188552','#3078bd','#8a50aa','#d39a00','#c35d9a','#65a8ae']
shapes=['list','form','tabs','nested','thread','cluster','table','modal','filter','summary']
fits=[]
for shape in [None,*shapes]:
 for mode in modes:
  rs=[r for r in rows if r['shape']==shape and r['mode']==mode]
  if not rs:continue
  x=np.array([r['n'] for r in rs]);y=np.array([r['rendering']['brotli'] for r in rs]);slope,baseline=np.polyfit(x,y,1)
  seed_slopes=[float(np.polyfit([r['n'] for r in rs if r['seed']==seed],[r['rendering']['brotli'] for r in rs if r['seed']==seed],1)[0]) for seed in [17,101,2027]]
  upper=[r for r in rs if r['n']>=8];upper_slope=float(np.polyfit([r['n'] for r in upper],[r['rendering']['brotli'] for r in upper],1)[0])
  fits.append(dict(shape=shape or 'mixed',mode=mode,baseline=float(baseline),slope=float(slope),seed_min=min(seed_slopes),seed_max=max(seed_slopes),upper_slope=upper_slope,rmse=float(np.sqrt(np.mean((y-(baseline+slope*x))**2))),runtime_N32=float(np.median([r['runtime']['brotli'] for r in rs if r['n']==32])),N32=float(np.median([r['rendering']['brotli'] for r in rs if r['n']==32])),max=max(int(v) for v in y)))
(H/'results/fits.json').write_text(json.dumps(fits,indent=2)+'\n')
with (H/'results/sizes.csv').open('w') as f:
 w=csv.writer(f,lineterminator="\n");w.writerow(['family','seed','N','mode','raw','brotli','gzip','runtime_brotli','app_increment_brotli','full_brotli'])
 for r in rows:w.writerow([r['shape'] or 'mixed',r['seed'],r['n'],r['mode'],*[r['rendering'][k] for k in ['raw','brotli','gzip']],r['runtime']['brotli'],r['app_in_rendering_context'],r['full']['brotli']])
plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,'figure.dpi':150,'svg.hashsalt':'rendering-design-172'})
(H/'results/graphs').mkdir(exist_ok=True)
def draw(ax,shape,solid=False):
 for mode,label,color in zip(modes,labels,colors):
  rs=[r for r in rows if r['shape']==shape and r['mode']==mode]
  if not rs:continue
  ns=sorted(set(r['n'] for r in rs));ys=[[r['rendering']['brotli']/1000 for r in rs if r['n']==n] for n in ns]
  ax.plot(ns,[np.median(y) for y in ys],label=label,color=color,marker='o',ms=3,lw=1.5)
  ax.fill_between(ns,[min(y) for y in ys],[max(y) for y in ys],color=color,alpha=.15)
 ax.set_xticks([1,8,16,24,32]);ax.set_xlim(0,33);ax.set_ylim(bottom=0);ax.grid(alpha=.15);ax.set_title(shape or 'Mixed app')
fig,ax=plt.subplots(figsize=(10,5.7));draw(ax,None);ax.set_xlabel('Independent shape instances (N)');ax.set_ylabel('Rendering response, brotli kB (1 kB = 1,000 B)');ax.legend(ncol=2,fontsize=9);fig.suptitle('Measured growth: 10 UI shapes, 3 seeds, real TEA source',weight='bold');fig.tight_layout();fig.savefig(H/'results/graphs/mixed-growth.png');fig.savefig(H/'results/graphs/mixed-growth.svg',metadata={'Date':None});plt.close(fig)
fig,axes=plt.subplots(5,2,figsize=(12,17),sharex=True)
for ax,shape in zip(axes.flat,shapes):draw(ax,shape);ax.set_ylabel('brotli kB')
for ax in axes[-1]:ax.set_xlabel('Shape instances (N)')
handles,legend=axes.flat[0].get_legend_handles_labels();fig.legend(handles,legend,loc='upper center',ncol=4,fontsize=9);fig.suptitle('Per-family growth; bands span three seeds',y=.995,weight='bold');fig.tight_layout(rect=[0,0,1,.955]);fig.savefig(H/'results/graphs/family-growth.png');fig.savefig(H/'results/graphs/family-growth.svg',metadata={'Date':None});plt.close(fig)
mat=np.array([[next(f['slope'] for f in fits if f['shape']==shape and f['mode']==mode) for mode in modes[:-1]] for shape in shapes])
fig,ax=plt.subplots(figsize=(11,6));im=ax.imshow(mat,cmap='YlOrRd',aspect='auto',vmin=0);ax.set_xticks(range(7),['Today\nTEA','Today\ndirect','Vanilla','A\npartial','B\nstatic','C\nlocal','D\ncells']);ax.set_yticks(range(10),shapes)
for i in range(10):
 for j in range(7):ax.text(j,i,f'{mat[i,j]:.0f}',ha='center',va='center',color='white' if mat[i,j]>mat.max()*.65 else 'black')
fig.colorbar(im,ax=ax,label='brotli bytes / added shape (OLS N=1…32)');ax.set_title('Which shapes grow fast? Baseline + slope fit, all three seeds');fig.tight_layout();fig.savefig(H/'results/graphs/slopes.png');fig.savefig(H/'results/graphs/slopes.svg',metadata={'Date':None});plt.close(fig)
lines=['# Baseline + slope results','','Brotli bytes; pooled ordinary least squares over N = 1, 2, 4, 8, 16, 32 and three seeds. The intercept is a fit, not a measured runtime. Seed range is variation, not a confidence interval. Runtime is source-provenance bytes compressed alone; it is not additive with separately compressed app bytes.','','| Family | Strategy | Fit baseline | B/shape | Seed slope range | N≥8 slope | RMSE | N32 median | Runtime N32 |','|---|---|---:|---:|---:|---:|---:|---:|---:|']
for f in fits:lines.append(f"| {f['shape']} | {f['mode']} | {f['baseline']:.0f} | {f['slope']:.1f} | {f['seed_min']:.1f}–{f['seed_max']:.1f} | {f['upper_slope']:.1f} | {f['rmse']:.0f} | {f['N32']:.0f} | {f['runtime_N32']:.0f} |")
(H/'results/fits.md').write_text('\n'.join(lines)+'\n')
if (H/'results/timing.json').exists():
 data=json.loads((H/'results/timing.json').read_text());samples=[r for r in data['samples'] if 'error' not in r];summary=[]
 for key in sorted(set((r['name'],r['operation'],r['mode']) for r in samples)):
  rs=[r for r in samples if (r['name'],r['operation'],r['mode'])==key];entry=dict(zip(['name','operation','mode'],key));entry['n']=len(rs)
  for metric in ['total','script','paint']:
   values=[r[metric] for r in rs];entry[metric]={'median':float(np.median(values)),'q1':float(np.quantile(values,.25)),'q3':float(np.quantile(values,.75))}
  summary.append(entry)
 (H/'results/timing-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 groups=sorted(set((r['name'],r['operation']) for r in summary));fig,axes=plt.subplots(3,3,figsize=(14,12))
 for ax,key in zip(axes.flat,groups):
  for j,(mode,label,color) in enumerate(zip(modes,labels,colors)):
   row=next((r for r in summary if (r['name'],r['operation'])==key and r['mode']==mode),None)
   if row:
    v=row['script'];ax.bar(j,v['median'],color=color);ax.errorbar(j,v['median'],yerr=[[max(0,v['median']-v['q1'])],[max(0,v['q3']-v['median'])]],color='black',capsize=2)
  ax.set_xticks(range(8),['tea','direct','JS','A','B','C','D','Solid'],rotation=40);ax.set_title(key[0]+' / '+key[1]);ax.set_ylabel('Script ms (median / IQR)');ax.grid(axis='y',alpha=.15)
 fig.suptitle('Real Chrome clicks on pinned azathoth; 12 trials, two warm cycles',weight='bold');fig.tight_layout(rect=[0,0,1,.965]);fig.savefig(H/'results/graphs/interactions.png');fig.savefig(H/'results/graphs/interactions.svg',metadata={'Date':None});plt.close(fig)

lines=['# Maximum rendering bundle by strategy and family','','Maximum over the measured N=1,2,4,8,16,32 and three seeds; brotli bytes.','','| Family | '+' | '.join(modes)+' |','|---|'+'---:|'*len(modes)]
for shape in ['mixed',*shapes]:
 vals=[next((str(f['max']) for f in fits if f['shape']==shape and f['mode']==mode),'—') for mode in modes]
 lines.append('| '+shape+' | '+' | '.join(vals)+' |')
(H/'results/max-matrix.md').write_text('\n'.join(lines)+'\n')

# Normalize SVG whitespace emitted by matplotlib for a clean, deterministic diff.
for file in (H/'results/graphs').glob('*.svg'):
 file.write_text('\n'.join(line.rstrip() for line in file.read_text().splitlines()).rstrip()+'\n')
