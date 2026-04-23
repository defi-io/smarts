import { Controller } from "@hotwired/stimulus"

// Copies the `text` value to the clipboard when the element is clicked.
// Usage:
//   <button data-controller="copy"
//           data-copy-text-value="hello"
//           data-action="click->copy#write">Copy</button>
export default class extends Controller {
  static values = { text: String }

  async write(event) {
    const button = event.currentTarget
    const original = button.textContent
    try {
      await navigator.clipboard.writeText(this.textValue)
      button.textContent = "Copied"
      setTimeout(() => { button.textContent = original }, 1500)
    } catch (err) {
      console.error("[copy] clipboard write failed", err)
      button.textContent = "Failed"
      setTimeout(() => { button.textContent = original }, 1500)
    }
  }
}
