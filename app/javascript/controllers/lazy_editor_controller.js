import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.details = this.element.closest("details")
    this.opened = () => { if (this.details?.open) this.element.loading = "eager" }
    this.details?.addEventListener("toggle", this.opened)
    this.opened()
  }

  disconnect() { this.details?.removeEventListener("toggle", this.opened) }

  unavailable(event) {
    // Retain the ordinary page link if the frame cannot be fetched or parsed.
    event.preventDefault()
    const message = this.element.querySelector("[role=status]")
    if (message) message.textContent = "The inline editor could not load. Open the editor below to try again."
  }
}
