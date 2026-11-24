import { Controller } from "@hotwired/stimulus"

// Match the compact layout while keeping native details/summary interaction.
export default class extends Controller {
  connect() {
    this.media = window.matchMedia("(max-width: 900px)")
    this.update = () => {
      this.element.open = !this.media.matches
      this.element.dataset.disclosureViewport = String(this.media.matches)
    }
    this.media.addEventListener("change", this.update)
    // Preserve the user's choice when Turbo restores a cached page.
    if (this.element.dataset.disclosureViewport !== String(this.media.matches)) {
      this.update()
    }
    this.element.setAttribute("data-disclosure-initialized", "")
  }

  disconnect() {
    this.media.removeEventListener("change", this.update)
  }
}
