import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "button"]
  static values = { label: String }

  connect() {
    this.hide()
    this.buttonTarget.hidden = false
  }

  disconnect() {
    this.hide()
  }

  preserveFocus(event) {
    if (document.activeElement === this.inputTarget) event.preventDefault()
  }

  toggle(event) {
    const { selectionStart, selectionEnd } = this.inputTarget
    this.setVisibility(this.inputTarget.type === "password")

    // Keep typing at the same position after a tap; keyboard users keep button focus.
    if (event.detail > 0) {
      this.inputTarget.focus({ preventScroll: true })
      this.inputTarget.setSelectionRange(selectionStart, selectionEnd)
    }
  }

  hide() {
    this.setVisibility(false)
  }

  setVisibility(visible) {
    const action = visible ? "Hide" : "Show"
    this.inputTarget.type = visible ? "text" : "password"
    this.buttonTarget.textContent = action
    this.buttonTarget.setAttribute("aria-label", `${action} ${this.labelValue}`)
  }
}
