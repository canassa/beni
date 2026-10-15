// Source catalogue only. No reads, writes or dependency annotations live here.
export const shapes = ['list','form','tabs','nested','thread','cluster','table','modal','filter','summary'];
export const counts = [1,2,4,8,16,32];
export const seeds = [17,101,2027];
export function random(seed) { let x=seed>>>0; return ()=>{x^=x<<13;x^=x>>>17;x^=x<<5;return (x>>>0)/4294967296;}; }
const indent=(s,n=4)=>s.split('\n').map(x=>' '.repeat(n)+x).join('\n');
const q=JSON.stringify;
export function component(shape, index, seed, population=20) {
 const rng=random(seed*65537+index*997+shapes.indexOf(shape)*8191);
 const variant=Math.floor(rng()*10000), depth=1+Math.floor(rng()*3), step=1+Math.floor(rng()*7);
 const suffix=String(variant), f=name=>name+suffix, m=name=>'model.'+f(name);
 const label=`${shape} ${seed}/${index} ${['Review','Work','People','Activity'][variant%4]}`;
 const id=`s${index}`, field=(name,type,init)=>({name:f(name),type,init});
 const button=(name,text= name,arg='')=>`<button id="${id}-${name.toLowerCase()}${arg ? "-"+arg : ""}" onClick={${name}${arg?' '+arg:''}}>${text}</button>`;
 let fields=[],messages=[],arms=[],helpers='',view='';
 const arm=(pattern,body)=>arms.push([pattern,body]);
 const change=entries=>`{ model | ${entries.map(([name,expr])=>f(name)+' = '+expr).join(', ')} }`;
 const counterAudit=variant%2===0;
 if(shape==='cluster') {
  fields=[field('count','Int','0'),field('enabled','Bool','True'),field('history','Int','0')];messages=['Increment','Toggle','Reset'];
  arm('Increment',change([['count',`${m('count')} + ${step}`],...(counterAudit?[['history',`${m('history')} + 1`]]:[])]));
  arm('Toggle',change([['enabled',`not ${m('enabled')}`],['history',`${m('history')} + 1`]]));
  arm('Reset',change([['count','0'],['history','0']]));
  view=`${button('Increment')}${button('Toggle')}${button('Reset')}<output id="${id}-count">{${m('count')}}</output><span hidden={not ${m('enabled')}}>{${m('history')}}</span>`;
 } else if(shape==='form') {
  fields=[field('name','String','""'),field('email','String','""'),field('submitted','Bool','False'),field('attempts','Int','0')];
  messages=['Name String','Email String','Submit','Reset'];
  arm('Name text',`if String.contains text "#" then model else ${change([['name','text'],...(counterAudit?[['submitted','False']]:[])])}`);
  arm('Email text',change([['email','text'],['submitted','False']]));
  arm('Submit',change([['submitted','True'],['attempts',`${m('attempts')} + 1`]]));
  arm('Reset',change([['name','""'],['email','""'],['submitted','False']]));
  view=`<label>Name<input id="${id}-name" value={${m('name')}} onInput={Name} /></label><label>Email<input id="${id}-email" value={${m('email')}} onInput={Email} /></label><p id="${id}-validation">{if String.length ${m('name')} < ${2+variant%4} then "Name too short" else if String.contains ${m('email')} "@" then "Ready" else "Email needs @"}</p>${button('Submit')}${button('Reset')}<p hidden={not ${m('submitted')}}>Saved {${m('name')}} / {${m('attempts')}}</p>`;
 } else if(shape==='tabs') {
  fields=[field('tab','Int','0'),field('unread','Int',String(step)),field('draft','String','""')];messages=['Choose Int','Read','Draft String'];
  arm('Choose tab',change([['tab','tab'],...(counterAudit?[['unread','0']]:[])]));
  arm('Read',change([['unread','0']]));arm('Draft text',change([['draft','text']]));
  view=`${button('Choose','Overview','0')}${button('Choose','Messages','1')}<div id="${id}-panel">{if ${m('tab')} == 0 then <article><h3>Overview</h3><p>{${m('unread')}} unread</p>${button('Read')}</article> else <aside><h3>Compose</h3><input id="${id}-draft" value={${m('draft')}} onInput={Draft} /><p>{${m('draft')}}</p></aside>}</div>`;
 } else if(shape==='nested') {
  fields=[field('left','Int','0'),field('right','Int',String(step)),field('expanded','Bool','True')];messages=['Child Bool Int','Collapse'];
  arm('Child left amount',`if left then ${change([['left',`${m('left')} + amount`]])} else ${change([['right',`${m('right')} + amount`],...(counterAudit?[['left',`${m('left')} + 1`]]:[])])}`);
  arm('Collapse',change([['expanded',`not ${m('expanded')}`]]));
  helpers=`card : String, Int, Bool → Html Msg\ncard title count left =\n    <article><h3>{title}</h3><output>{count}</output><button onClick={Child left ${step}}>Child action</button></article>\n\nbranch : Int, Int, Bool → Html Msg\nbranch level count left =\n    if level == 0 then card "Leaf" count left else <div class="nested">{branch (level - 1) count left}</div>`;
  view=`${button('Collapse')}<p id="${id}-total">{${m('left')} + ${m('right')}}</p><div hidden={not ${m('expanded')}}>{branch ${depth} ${m('left')} True}{branch ${depth+1} ${m('right')} False}</div>`;
 } else if(shape==='thread') {
  fields=[field('tree','Thread',`Comment 0 "Root ${variant}" 0 [ Comment 1 "First" 0 [ Comment 2 "Nested" 0 [] ], Comment 3 "Second" 0 [] ]`),field('collapsed','Bool','False')];
  messages=['Vote Int','Rename Int String','Collapse'];
  arm('Vote wanted',change([['tree',`vote wanted ${m('tree')}`]]));arm('Rename wanted title',change([['tree',`rename wanted title ${m('tree')}`]]));arm('Collapse',change([['collapsed',`not ${m('collapsed')}`]]));
  helpers=`type Thread\n    = Comment Int String Int (List Thread)\n\nvote : Int, Thread → Thread\nvote wanted tree =\n    case tree of\n        Comment id title score children →\n            Comment id title (if id == wanted then score + ${step} else score) (List.map children (vote wanted _))\n\nrename : Int, String, Thread → Thread\nrename wanted text tree =\n    case tree of\n        Comment id title score children →\n            Comment id (if id == wanted then text else title) score (List.map children (rename wanted text _))\n\nthreadKey : Thread → Int\nthreadKey tree =\n    case tree of\n        Comment id _ _ _ → id\n\ncomment : Thread → Html Msg\ncomment tree =\n    case tree of\n        Comment id title score children →\n            <article data-comment={String.fromInt id}><strong>{title}</strong><output>{score}</output><button onClick={Vote id}>Vote</button><input value={title} onInput={Rename id _} /><div><For each={children} keyed={threadKey}>{λchild → comment child}</For></div></article>`;
  view=`${button('Collapse')}<div hidden={${m('collapsed')}}>{comment ${m('tree')}}</div>`;
 } else if(shape==='modal') {
  fields=[field('open','Bool','False'),field('draft','String','""'),field('saved','String','""'),field('visits','Int','0')];messages=['Open','Close','Draft String','Confirm'];
  arm('Open',change([['open','True'],['draft',m('saved')],['visits',`${m('visits')} + 1`]]));
  arm('Close',change([['open','False']]));arm('Draft text',change([['draft','text']]));arm('Confirm',change([['open','False'],['saved',m('draft')]]));
  view=`${button('Open')}<output id="${id}-saved">{${m('saved')}}</output><span>{${m('visits')}}</span>{if ${m('open')} then <div role="dialog" aria-label="Edit"><h3>Edit ${variant}</h3><input id="${id}-draft" value={${m('draft')}} onInput={Draft} />${button('Confirm')}${button('Close')}</div> else <></>}`;
 } else {
  fields=[field('rows','List Row',`List.map (List.range 1 ${population}) λi → { id = i, title = "Item " ++ String.fromInt i, score = Int.mod (i * ${step}) 17, done = False }`),field('next','Int',String(population+1)),field('selected','Int','0')];
  messages=['Add','Remove Int','Edit Int','Select Int','Reverse'];
  arm('Add',change([['rows',`[ …${m('rows')}, { id = ${m('next')}, title = "${label} " ++ String.fromInt ${m('next')}, score = ${step}, done = False } ]`],['next',`${m('next')} + 1`]]));
  arm('Remove wanted',change([['rows',`List.filter ${m('rows')} λrow → row.id ≠ wanted`],...(counterAudit?[['selected','0']]:[])]));
  arm('Edit wanted',change([['rows',`List.map ${m('rows')} λrow → if row.id == wanted then { row | title = row.title ++ "!", score = row.score + ${step}, done = not row.done } else row`]]));
  arm('Select wanted',change([['selected','wanted']]));arm('Reverse',change([['rows',`List.reverse ${m('rows')}`]]));
  helpers=`type alias Row =\n    id : Int\n    title : String\n    score : Int\n    done : Bool`;
  let each=m('rows'), row=`<li data-row={String.fromInt row.id} class={if ${m('selected')} == row.id then "selected" else ""}><button onClick={Select row.id}>{row.title}</button><output>{row.score}</output><button onClick={Edit row.id}>Edit</button><button onClick={Remove row.id}>Remove</button></li>`;
  if(shape==='table') {
   fields.push(field('descending','Bool','False'));messages.push('Sort');arm('Sort',change([['descending',`not ${m('descending')}`]]));
   each=`if ${m('descending')} then List.reverse (List.sortBy ${m('rows')} .score) else List.sortBy ${m('rows')} .score`;
   row=`<tr data-row={String.fromInt row.id} class={if ${m('selected')} == row.id then "selected" else ""}><td><button onClick={Select row.id}>{row.title}</button></td><td>{row.score}</td><td><button onClick={Edit row.id}>Edit</button><button onClick={Remove row.id}>Remove</button></td></tr>`;
  }
  if(shape==='filter') {
   fields.push(field('query','String','""'),field('onlyDone','Bool','False'));messages.push('Query String','OnlyDone');arm('Query text',change([['query','text']]));arm('OnlyDone',change([['onlyDone',`not ${m('onlyDone')}`]]));
   each=`List.filter ${m('rows')} λrow → String.contains row.title ${m('query')} && (not ${m('onlyDone')} || row.done)`;
  }
  if(shape==='summary') {
   fields.push(field('rate','Int',String(step)));messages.push('Rate');arm('Rate',change([['rate',`${m('rate')} + 1`]]));
   helpers+=`\n\ntotal : List Row → Int\ntotal rows = List.foldl rows 0 (λrow sum → sum + row.score)`;
  }
  const list=shape==='table'?`<table><thead><tr><th>${button('Sort')}</th><th>Score</th><th>Actions</th></tr></thead><tbody><For each={${each}} keyed={.id}>{λrow → ${row}}</For></tbody></table>`:`<ul><For each={${each}} keyed={.id}>{λrow → ${row}}</For></ul>`;
  view=`${button('Add')}${button('Reverse')}${shape==='filter'?`<input id="${id}-query" value={${m('query')}} onInput={Query} />${button('OnlyDone')}`:''}${shape==='summary'?`${button('Rate')}<dl><dt>Total</dt><dd id="${id}-total">{total ${m('rows')} * ${m('rate')}}</dd><dt>Completed</dt><dd>{List.length (List.filter ${m('rows')} .done)}</dd></dl>`:''}<p>{List.length ${m('rows')}} records</p>${list}`;
 }
 // Vary static nesting as well as fields and transitions; never pass dependency metadata.
 for(let n=0;n<depth-1;n++)view=`<div class="level-${n}">${view}</div>`;
 const source=`import Html exposing (Html)\n\n${helpers}\n\npub type alias Model =\n${fields.map(x=>'    '+x.name+' : '+x.type).join('\n')}\n\npub type Msg\n    = ${messages.join('\n    | ')}\n\npub init : ⊤ → Model\ninit ⊤ = { ${fields.map(x=>x.name+' = '+x.init).join(', ')} }\n\npub update : Msg, Model → Model\nupdate msg model =\n    case msg of\n${arms.map(([p,b])=>'        '+p+' →\n'+indent(b,12)).join('\n\n')}\n\npub view : Model → Html Msg\nview model =\n    <section id="${id}" data-shape="${shape}"><h2>${label}</h2>${view}</section>\n`;
 return {shape,index,seed,variant,depth,step,source};
}
export function application(n,seed,onlyShape=null,population=20) {
 const rng=random(seed), order=shapes.slice();
 for(let i=order.length-1;i>0;i--){const j=Math.floor(rng()*(i+1));[order[i],order[j]]=[order[j],order[i]];}
 const parts=Array.from({length:n},(_,i)=>component(onlyShape||order[i%order.length],i,seed,population));
 const source=`import Browser\nimport Html exposing (Html)\nimport Tea\n${parts.map((_,i)=>`import Shape${i}`).join('\n')}\n\ntype alias Model =\n${parts.map((_,i)=>`    part${i} : Shape${i}.Model`).join('\n')}\n\ntype Msg\n    = ${parts.map((_,i)=>`Part${i} Shape${i}.Msg`).join('\n    | ')}\n\nupdate : Msg, Model → Model\nupdate msg model =\n    case msg of\n${parts.map((_,i)=>`        Part${i} child →\n            { model | part${i} = Shape${i}.update child model.part${i} }`).join('\n\n')}\n\nview : Model → Html Msg\nview model =\n    <main>\n${parts.map((_,i)=>`        {Html.map (Shape${i}.view model.part${i}) Part${i}}`).join('\n')}\n    </main>\n\nmain : Browser.Program\nmain = Tea.sandbox { init = λ⊤ → { ${parts.map((_,i)=>`part${i} = Shape${i}.init ⊤`).join(', ')} }, update = update, view = view }\n`;
 return {n,seed,onlyShape,population,parts,source};
}
