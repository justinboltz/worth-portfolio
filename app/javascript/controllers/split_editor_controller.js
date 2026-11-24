import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rows", "row", "amount", "feedback", "template", "remove", "add"]
  static values = { total: String, currency: String }

  connect() {
    this.nextIndex = Math.max(-1, ...this.rowTargets.map(row => Number(row.dataset.splitIndex))) + 1
    this.addTarget.hidden = false
    this.feedbackTarget.hidden = false
    this.update()
  }

  add() {
    const index = this.nextIndex++
    this.rowsTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("__INDEX__", index).replaceAll("__NUMBER__", index + 1))
    this.update()
    this.rowTargets.at(-1).querySelector("input").focus()
  }

  remove(event) {
    if (this.rowTargets.length <= 2) return
    const row = event.target.closest("[data-split-editor-target='row']")
    const index = this.rowTargets.indexOf(row)
    row.remove()
    this.update()
    this.rowTargets[Math.min(index, this.rowTargets.length - 1)].querySelector("input").focus()
  }

  // Decimal arithmetic to four places matches the stored financial precision.
  units(value) {
    const match = value.trim().match(/^(-?)(\d+)(?:\.(\d{0,4}))?$/)
    if (!match) return null
    return (match[1] ? -1n : 1n) * BigInt(match[2] + (match[3] || "").padEnd(4, "0"))
  }

  format(value) {
    return new Intl.NumberFormat(undefined, { style: "currency", currency: this.currencyValue, maximumFractionDigits: 4 }).format(Number(value) / 10000)
  }

  update() {
    this.removeTargets.forEach(button => { button.hidden = false; button.disabled = this.rowTargets.length <= 2 })
    const values = this.amountTargets.filter(input => input.value !== "").map(input => this.units(input.value))
    if (values.includes(null)) {
      this.feedbackTarget.textContent = "Use amounts with no more than four decimal places."
      return
    }
    const total = this.units(this.totalValue)
    if (total === null) return
    const allocated = values.reduce((sum, value) => sum + value, 0n)
    const remaining = total - allocated
    this.feedbackTarget.textContent = `${this.format(allocated)} allocated · ${remaining === 0n ? "Amounts match the original" : `${this.format(remaining)} remaining to allocate`}`
    this.feedbackTarget.classList.toggle("is-balanced", remaining === 0n && values.length >= 2)
  }
}
