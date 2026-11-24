import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toolbar", "all", "item", "count", "clear", "panel", "submit"]

  connect() {
    this.toolbarTarget.hidden = this.itemTargets.length === 0
    this.update()
  }

  update() {
    const selected = this.itemTargets.filter(item => item.checked).length
    this.countTarget.textContent = selected ? `${selected} selected` : ""
    this.allTarget.checked = selected > 0 && selected === this.itemTargets.length
    this.allTarget.indeterminate = selected > 0 && selected < this.itemTargets.length
    this.clearTarget.disabled = selected === 0
    this.clearTarget.hidden = selected === 0
    this.panelTarget.hidden = selected === 0
    const hasChanges = [...this.panelTarget.querySelectorAll("select, input:not([type=submit])")].some(input => input.value.trim() !== "")
    this.submitTarget.disabled = selected === 0 || !hasChanges
    this.itemTargets.forEach(item => item.closest("tr").classList.toggle("is-selected", item.checked))
  }

  toggleAll() {
    this.itemTargets.forEach(item => { item.checked = this.allTarget.checked })
    this.update()
  }

  clear() {
    this.itemTargets.forEach(item => { item.checked = false })
    this.update()
  }

  reset() {
    this.clear()
    this.panelTarget.open = false
  }
}
