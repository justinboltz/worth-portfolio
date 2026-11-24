# Worth

Worth is a personal finance app for people who want to see where their money goes, plan for upcoming bills, and track what they own and owe. You can enter transactions by hand or import them. You don't need to connect a bank to try it.

## What you can do

- **Understand your spending.** Search, filter, split, and categorize transactions; separate transfers and card payments from spending.
- **Plan ahead.** Set category budgets, carry unused amounts forward, and see a 30-day outlook for recurring bills and income.
- **See the bigger picture.** Compare spending and income by period and track net worth from historical balance snapshots and manually valued assets.
- **Bring your own history.** Preview and map columns in Mint-style CSV exports, or import saved values from a Tiller workbook. Worth flags possible duplicates for review.
- **Connect a bank if you choose.** Plaid integration can read balances and transactions. Worth cannot move money or pay bills.

## Try it with fictional data

This demo runs on your machine, doesn't connect to Plaid, and binds only to localhost. It starts its own temporary PostgreSQL cluster rather than reading or changing another database.

1. Install Ruby **3.3.10**, Bundler **4.0.4**, and PostgreSQL **16** command-line tools. Make sure `initdb` and `pg_ctl` are on your PATH. Run as a regular user, not root.
2. In a fresh checkout, run:

   ```sh
   gem install bundler -v 4.0.4
   bundle install
   bin/demo
   ```

3. Open [the local sign-in page](http://127.0.0.1:3000/sign_in). Sign in with **demo@example.com** and **worth-demo-local**. These are fictional credentials for this offline demo, not a real account.
4. On the dashboard, open **Transactions**, **Budgets**, **Recurring**, or **Trends** to explore the sample history.

Press Ctrl+C to stop the app and discard its synthetic database. If port 3000 is already in use, run `PORT=3001 bin/demo`. This is a local demo, not a production configuration.

## Development

Worth uses Ruby on Rails 8.1, PostgreSQL, Hotwire, and server-rendered views. The optional [Android prototype](android/README.md) wraps the same web app with Hotwire Native. The local demo does not require Android tooling.

For ongoing development, use a dedicated **local** PostgreSQL database and set `DATABASE_USERNAME`, `DATABASE_PASSWORD`, and `DATABASE_HOST` as needed. The [environment template](.env.example) lists the supported variables. Supply them through your shell; copying the template alone won't load it. Then run `bin/rails db:prepare` and `bin/rails server --binding 127.0.0.1`.

The test workflow provisions its own PostgreSQL service and dummy encryption keys. See [the CI configuration](.github/workflows/ci.yml) for the exact setup. Use disposable test data only. The app uses positive amounts for outflows and negative amounts for inflows. It keeps currencies separate and does not convert them.

For optional Plaid development use your own sandbox credentials, never a real institution or production key. Configure separate Active Record encryption keys for encrypted tokens (see the environment template). Do not commit keys, personal exports, or database contents.
