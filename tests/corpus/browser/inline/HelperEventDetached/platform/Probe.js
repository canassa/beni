// Host-only fixture instrumentation; no beni callback is erased.
const click=node=>{node.dispatchEvent(new globalThis.MouseEvent("click",{bubbles:true,cancelable:true}));};
const report=(label,node)=>{const event=new globalThis.MouseEvent("click",{bubbles:true,cancelable:true});node.dispatchEvent(event);globalThis.console.log(label,event.defaultPrevented);};
export const detach = () => {
 const root=globalThis.document.getElementById("root");globalThis.window.detachedRoot=root;const insert=root.insertAdjacentHTML;
 root.insertAdjacentHTML=(position,html)=>{insert.call(root,position,html);globalThis.window.savedLocal=root.querySelector("[data-role=local]");globalThis.window.savedPiece=root.querySelector("[data-role=piece]");globalThis.window.savedRetained=root.querySelector("[data-role=retainedone]");globalThis.window.savedTwinOne=root.querySelector("[data-role=twinone] button");globalThis.window.savedTwinTwo=root.querySelector("[data-role=twintwo] button");};
 const afterstop=()=>{report("local",globalThis.window.savedLocal);report("piece",globalThis.window.savedPiece);report("piece-current",globalThis.window.savedCurrentPiece);report("old-binding",globalThis.window.savedRetained);report("new-binding",globalThis.window.savedCurrent);report("shown-sibling",globalThis.window.savedTwinOne);report("hidden-sibling",globalThis.window.savedTwinTwo);};
 globalThis.window.addEventListener("afterstop",afterstop);root.remove();return null;
};
export const start = send => {
 const root=globalThis.window.detachedRoot; const local=globalThis.window.savedLocal; const piece=globalThis.window.savedPiece; const retained=globalThis.window.savedRetained; const twinOne=globalThis.window.savedTwinOne; const twinTwo=globalThis.window.savedTwinTwo;
 const old=()=>{click(local);click(piece);click(retained);click(twinOne);click(twinTwo);}; const next=()=>send(1); const current=()=>{const node=root.querySelector("[data-role=retainedtwo]");globalThis.window.savedCurrent=node;globalThis.window.savedCurrentPiece=root.querySelector("[data-role=piece-next]");click(node);};
 globalThis.window.addEventListener("old",old);globalThis.window.addEventListener("next",next);globalThis.window.addEventListener("current",current);
 return ()=>{globalThis.window.removeEventListener("old",old);globalThis.window.removeEventListener("next",next);globalThis.window.removeEventListener("current",current);return null;};
};
