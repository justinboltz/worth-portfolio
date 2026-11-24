import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  close(event) {
    if (!this.element.open) return
    event.preventDefault()
    this.element.open = false
    this.element.querySelector("summary").focus()
  }

  outside(event) {
    if (!this.element.contains(event.target)) this.element.open = false
  }

  reset() { this.element.open = false }
}
