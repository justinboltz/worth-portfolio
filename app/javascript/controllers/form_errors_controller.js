import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { attributes: Array }

  connect() {
    const scope = this.element.closest("form") || this.element.parentElement
    for (const input of scope.querySelectorAll("input, select, textarea")) {
      if (this.attributesValue.some(attribute => input.name.endsWith(`[${attribute}]`))) {
        input.setAttribute("aria-invalid", "true")
        const descriptions = new Set((input.getAttribute("aria-describedby") || "").split(" ").filter(Boolean))
        descriptions.add(this.element.id)
        input.setAttribute("aria-describedby", [...descriptions].join(" "))
      }
    }
    // Put validation feedback within reach after a Turbo form replacement.
    this.frame = requestAnimationFrame(() => this.element.focus())
  }

  disconnect() {
    cancelAnimationFrame(this.frame)
  }
}
