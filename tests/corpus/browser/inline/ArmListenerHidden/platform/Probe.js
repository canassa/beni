// Host-only fixture instrumentation; no beni callback is erased.
export const keep = () => {
 const root=globalThis.document.getElementById("root"); const insert=root.insertAdjacentHTML;
 root.insertAdjacentHTML=(position,html)=>{insert.call(root,position,html);globalThis.window.kept=root.querySelectorAll("[data-poke]");};
 return null;
};
export const start = _send => {
 const poke=()=>{for(const node of globalThis.window.kept)node.dispatchEvent(new globalThis.MouseEvent("click",{bubbles:true,cancelable:true}));};
 globalThis.window.addEventListener("poke",poke);
 return ()=>{globalThis.window.removeEventListener("poke",poke);return null;};
};
