import { Controller } from "@hotwired/stimulus"

// Fallback for environments where Turbo Stream broadcasts don't reach the
// browser (websocket blocked, CDN strips Upgrade headers, etc.). When the
// Governance partial is rendered with refreshing=true, this controller
// schedules a single Turbo Frame reload — the next response either returns
// the populated partial (no more controller, no more polling) or another
// refreshing state (which polls again). Cheap and self-terminating.
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 4000 },
    frameId: { type: String, default: "contract_governance" }
  }

  connect() {
    this.timer = setTimeout(() => this.reloadFrame(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  reloadFrame() {
    const frame = document.getElementById(this.frameIdValue)
    if (!frame) return
    frame.src = window.location.href
  }
}
