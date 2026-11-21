// Run in the beni-website hero with ?edit, as --wait-js: hide the ringed planet (the group whose first
// child is the sphere of radius 34, PLANET_R in src/scenery.js), the hero canvas and the page's text.
(() => {
  if (!window.scenery) return false;
  window.scenery.scene.traverse((o) => {
    if (o.isGroup && o.children[0]?.geometry?.parameters?.radius === 34) o.visible = false;
  });
  const s = document.createElement("style");
  s.textContent = ".stage canvas, .tagline, .cue, #ui, .lil-gui { visibility: hidden !important }";
  document.head.append(s);
  return true;
})()
