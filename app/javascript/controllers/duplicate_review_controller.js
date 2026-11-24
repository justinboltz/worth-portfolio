import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "submit", "status"]

  connect() { this.update() }

  update() {
    const selected = this.itemTargets.filter(item => item.checked).length
    const keepsOriginal = selected < this.itemTargets.length
    this.submitTarget.disabled = selected === 0 || !keepsOriginal
    this.statusTarget.textContent = !keepsOriginal ? "Leave at least one original unselected." : selected ? `${selected} ${selected === 1 ? "copy" : "copies"} will be excluded from reports.` : "Select only the copies to exclude."
    this.itemTargets.forEach(item => item.closest("tr").classList.toggle("is-selected", item.checked))
  }
}
