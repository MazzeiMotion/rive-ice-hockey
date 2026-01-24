// This is the High level JS runtime for Rive
// https://rive.app/community/doc/web-js/docvlgbnS1mp

const riveInstance = new rive.Rive({
  src: "scripted_ice_hockey.riv",
  canvas: document.getElementById("canvas"),
  autoplay: true,
  artboard: "Game",
  stateMachines: "State Machine 1",
  autoBind: true,
  enableMultiTouch: true,
  layout: new rive.Layout({
    fit: rive.Fit.Layout,
    // layoutScaleFactor: 2, // 2x scale of the layout, when using `Fit.Layout`. This allows you to resize the layout as needed.
  }),

  onLoad: () => {
    computeSize();
  },
});

function computeSize() {
  riveInstance.resizeDrawingSurfaceToCanvas();
}

// Subscribe to window size changes and update call `resizeDrawingSurfaceToCanvas`
window.onresize = computeSize;

// Subscribe to devicePixelRatio changes and call `resizeDrawingSurfaceToCanvas`
window
  .matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`)
  .addEventListener("change", computeSize);
