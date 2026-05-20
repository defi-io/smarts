import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    interval: { type: Number, default: 30000 },
    frameId: { type: String, default: "polymarket_live_markets" }
  }

  connect() {
    this.timer = setInterval(() => this.reloadFrame(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  reloadFrame() {
    const frame = document.getElementById(this.frameIdValue)
    if (!frame) return
    frame.src = window.location.href
  }
}
