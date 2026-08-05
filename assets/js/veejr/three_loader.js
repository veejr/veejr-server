// Shared, lazy loader for the vendored three.js build.
//
// Three.js is served from this instance (priv/static/vendor) rather than a
// CDN so the Content-Security-Policy can keep script-src pinned to 'self',
// and it is fetched only when a page actually needs WebGL — most sessions
// never open one.
//
// The cached promise lives here rather than in each caller so that opening
// the 3D contacts view and then the craps table reuses one download instead
// of racing two script tags for the same 669KB.

let threeLoader = null

export function loadThree(src) {
  if (window.THREE) return Promise.resolve(window.THREE)
  if (threeLoader) return threeLoader

  threeLoader = new Promise((resolve, reject) => {
    const tag = document.createElement("script")
    tag.src = src
    tag.async = true
    tag.onload = () => (window.THREE ? resolve(window.THREE) : reject(new Error("three absent")))
    tag.onerror = () => reject(new Error("three failed to load"))
    document.head.appendChild(tag)
  })

  // Let a later attempt retry rather than caching the rejection forever.
  threeLoader.catch(() => {
    threeLoader = null
  })
  return threeLoader
}

export function webglAvailable() {
  try {
    const c = document.createElement("canvas")
    return !!(window.WebGLRenderingContext && (c.getContext("webgl2") || c.getContext("webgl")))
  } catch (_e) {
    return false
  }
}
