export const defect=()=>{throw new globalThis.TypeError("layered original defect")};
export const stopped=()=>{
  globalThis.console.log("platform defect hook");
  globalThis.document.querySelector("button").disabled=true;
};
