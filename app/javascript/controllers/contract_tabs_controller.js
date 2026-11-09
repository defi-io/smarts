import { Controller } from "@hotwired/stimulus"

// Manages DaisyUI tab ↔ Turbo Frame lazy loading.
//
// The shell page renders Docs inline and two empty <turbo-frame> placeholders
// for Activity and Source. This controller:
//   1. On tab click, sets `frame.src` to the island URL (fetched once).
//   2. On connect, auto-selects the Activity tab when the URL carries a legacy
//      `?event_name=…` query param.
export default class extends Controller {
  static targets = ["activity", "source"]
  static values  = {
    activityUrl: String,
    sourceUrl:   String
  }

  connect() {
    this.loaded = new Set()

    const params = new URLSearchParams(window.location.search)
    if (params.has("event_name")) {
      this.show("activity")
      const url = this.appendParams(this.activityUrlValue, params, ["event_name"])
      this.loadFrame("contract_activity", url)
    }
  }

  loadTab(event) {
    const target = event.target
    // hasXTarget guards required because docs_only chains omit the activity
    // tab entirely — accessing this.activityTarget when the target
    // is absent throws and aborts the handler, blocking source from loading too.
    if (this.hasActivityTarget   && target === this.activityTarget)   this.loadFrame("contract_activity",   this.activityUrlValue)
    if (this.hasSourceTarget     && target === this.sourceTarget)     this.loadFrame("contract_source",     this.sourceUrlValue)
  }

  // ── private ──────────────────────────────────────────────────────────

  loadFrame(frameId, url) {
    if (this.loaded.has(frameId)) return
    const frame = document.getElementById(frameId)
    if (!frame) return
    frame.src = url
    this.loaded.add(frameId)
  }

  show(target) {
    if (target === "activity"   && this.hasActivityTarget)   this.activityTarget.checked = true
  }

  appendParams(base, params, keys) {
    const url = new URL(base, window.location.origin)
    keys.forEach(key => {
      if (params.has(key)) url.searchParams.set(key, params.get(key))
    })
    return url.pathname + url.search
  }
}
