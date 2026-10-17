// Fixed non-rendering support for the prototype. Excluded from rendering bytes.
// The supported operations have the same subject-first, total array semantics.
export const List_range=(a,b)=>Array.from({length:Math.max(0,b-a+1)},(_,i)=>a+i);
export const List_map=(xs,f)=>xs.map(f);
export const List_filter=(xs,f)=>xs.filter(f);
export const List_append=(xs,ys)=>xs.concat(ys);
export const List_reverse=xs=>xs.toReversed();
export const List_sortBy=(xs,f)=>xs.toSorted((a,b)=>{a=f(a);b=f(b);return a<b?-1:a>b?1:0});
export const List_length=xs=>xs.length;
export const List_foldl=(xs,initial,f)=>xs.reduce((a,x)=>f(x,a),initial);
export const String_fromInt=String;
export const String_length=s=>Array.from(s).length;
export const String_contains=(s,needle)=>s.includes(needle);
export const Int_mod=(a,b)=>b===0?0:((a%b)+b)%b;
// Owned-array forms are selected only by ownership.mjs's BIR proof.
export const Owned_map=(xs,f)=>{for(let i=0;i<xs.length;i++)xs[i]=f(xs[i]);return xs};
export const Owned_filter=(xs,f)=>{let end=0;for(const x of xs)if(f(x))xs[end++]=x;xs.length=end;return xs};
export const Owned_append=(xs,ys)=>{for(const y of ys)xs.push(y);return xs};
export const Owned_reverse=xs=>xs.reverse();
