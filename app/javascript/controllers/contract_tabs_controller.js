import { Controller } from "@hotwired/stimulus"

// Keeps the right tab selected when a filter query updates via Turbo Frame
// (so the radio input the server marked checked stays visually checked even
// after a frame-only swap), and when a user lands directly on a URL whose
// query implies a non-Docs tab.
export default class extends Controller {
  static targets = ["activity", "governance"]

  connect() {
    const params = new URLSearchParams(window.location.search)
    if (params.has("event_name")) this.show("activity")
    else if (params.has("gov_category")) this.show("governance")
  }

  show(target) {
    if (target === "activity" && this.hasActivityTarget) this.activityTarget.checked = true
    if (target === "governance" && this.hasGovernanceTarget) this.governanceTarget.checked = true
  }
}
