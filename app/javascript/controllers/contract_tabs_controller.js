import { Controller } from "@hotwired/stimulus"

// Keeps the Live Activity tab selected when activity filters update via Turbo
// Frame, and when a user lands directly on ?event_name=Transfer.
export default class extends Controller {
  static targets = ["activity"]

  connect() {
    const params = new URLSearchParams(window.location.search)
    if (params.has("event_name")) this.showActivity()
  }

  showActivity() {
    if (this.hasActivityTarget) this.activityTarget.checked = true
  }
}
