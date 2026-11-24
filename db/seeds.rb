def system_category!(name, parent: nil)
  category = Category.find_or_create_by!(user_id: nil, parent: parent, name: name) do |c|
    c.system = true
  end
  category.update!(system: true)
  category
end

income = system_category!("Income")
system_category!("Paycheck", parent: income)
system_category!("Interest Income", parent: income)
system_category!("Other Income", parent: income)

bills = system_category!("Bills & Utilities")
system_category!("Electricity", parent: bills)
system_category!("Gas", parent: bills)
system_category!("Internet", parent: bills)
system_category!("Mobile Phone", parent: bills)
system_category!("Rent", parent: bills)
system_category!("Water", parent: bills)

food = system_category!("Food & Dining")
system_category!("Groceries", parent: food)
system_category!("Restaurants", parent: food)
system_category!("Coffee Shops", parent: food)

shopping = system_category!("Shopping")
system_category!("Clothing", parent: shopping)
system_category!("Electronics & Software", parent: shopping)
system_category!("Home Goods", parent: shopping)

auto = system_category!("Auto & Transport")
system_category!("Gas & Fuel", parent: auto)
system_category!("Parking", parent: auto)
system_category!("Public Transportation", parent: auto)

system_category!("Entertainment")
system_category!("Health & Fitness")
system_category!("Travel")
system_category!("Fees & Charges")
system_category!("Gifts & Donations")
system_category!("Taxes")
