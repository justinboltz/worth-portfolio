import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "status"]

  disconnect() {
    this.handler?.destroy()
    this.abort?.abort()
  }

  async open() {
    if (this.buttonTarget.disabled) return
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Connecting…"
    this.statusTarget.textContent = "Opening a secure connection with Plaid…"
    try {
      if (!window.Plaid) throw new Error("Plaid could not load. Check your connection and try again, or import a CSV.")
      if (!this.handler) {
        const { link_token: token } = await this.post("/api/v1/plaid/link_token")
        if (!token) throw new Error("Bank connection is temporarily unavailable. Please try again later.")
        this.handler = window.Plaid.create({
          token,
          onSuccess: (publicToken, metadata) => this.save(publicToken, metadata),
          onExit: error => {
            this.statusTarget.textContent = error ? "The connection was not completed. You can try again or import a CSV." : "Connection canceled. No new bank connection was saved."
            if (error) { this.handler?.destroy(); this.handler = null }
            this.resetButton()
          }
        })
      }
      this.handler.open()
    } catch (error) {
      if (error.name === "AbortError") return
      this.statusTarget.textContent = error.message
      this.handler?.destroy()
      this.handler = null
      this.resetButton()
    }
  }

  async save(publicToken, metadata) {
    this.statusTarget.textContent = "Saving your connection. Please keep this page open…"
    this.buttonTarget.textContent = "Saving connection…"
    try {
      await this.post("/api/v1/plaid/exchange_public_token", {
        public_token: publicToken,
        institution_id: metadata?.institution?.institution_id,
        institution_name: metadata?.institution?.name
      })
      window.location.assign("/")
    } catch (error) {
      if (error.name === "AbortError") return
      // The server may have saved the connection before the response was lost.
      // Keep repeat exchanges disabled to avoid creating a duplicate connection.
      this.statusTarget.textContent = "We could not confirm whether the connection was saved. Return to the overview and check your connections before trying to link this bank again."
      this.buttonTarget.textContent = "Check connection on overview"
    }
  }

  resetButton() {
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = "Connect with Plaid"
  }

  async post(path, payload = {}) {
    this.abort = new AbortController()
    const response = await fetch(path, {
      method: "POST", signal: this.abort.signal,
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      body: JSON.stringify(payload)
    }).catch(error => {
      if (error.name === "AbortError") throw error
      throw new Error("Could not reach Worth. Check your connection and try again.")
    })
    if (response.status === 401) throw new Error("Your session expired. Sign in again to connect your bank.")
    if (!response.ok) throw new Error("Bank connection is temporarily unavailable. Please try again later or import a CSV.")
    return response.json().catch(() => { throw new Error("Bank connection is temporarily unavailable. Please try again later.") })
  }
}
