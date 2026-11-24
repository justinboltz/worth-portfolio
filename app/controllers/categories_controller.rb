class CategoriesController < ApplicationController
  before_action :require_authentication
  def index
    load_categories
  end
  def edit
    @category = Category.for_user(current_user).find(params[:id])
    @categories = Category.for_user(current_user).includes(:parent).sort_by(&:display_name)
  end
  def load_categories
    @draft ||= current_user.categories.new
    @categories = Category.for_user(current_user).includes(:parent).sort_by(&:display_name)
    @visible_categories = @categories.select do |category|
      matches_text = params[:q].blank? || category.display_name.downcase.include?(params[:q].strip.downcase)
      matches_kind = params[:kind].blank? || (params[:kind] == "system" && category.system?) || (params[:kind] == "personal" && category.user_id == current_user.id)
      matches_text && matches_kind
    end
  end
  def create
    @draft = current_user.categories.new(category_params)
    @draft.save!
    redirect_to categories_path, notice: "Category created."
  rescue ActiveRecord::RecordInvalid => e
    load_categories
    render :index, status: :unprocessable_entity
  end
  def update
    @editing_category = category = current_user.categories.find(params[:id])
    Category.transaction do
      category.update!(category_params)
      current_user.transactions.where(category_id: category.subtree_ids).update_all(category_locked: true, category_origin: "manual", category_reason: "Your category edit")
    end
    CashFlowClassifier.call(user: current_user)
    AutoCategorizer.call(user: current_user)
    redirect_to categories_path, notice: "Category updated."
  rescue ActiveRecord::RecordInvalid => e
    load_categories
    @visible_categories = @visible_categories.map { |category| category.id == @editing_category.id ? @editing_category : category }
    render :index, status: :unprocessable_entity
  end
  def expense_type
    category = Category.for_user(current_user).find(params[:id])
    choice = params.require(:expense_type)
    if choice == "automatic"
      current_user.category_expense_types.where(category: category).destroy_all
    else
      preference = current_user.category_expense_types.find_or_initialize_by(category: category)
      preference.update!(expense_type: choice)
    end
    redirect_to categories_path, notice: "Expense type updated for your reports."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to categories_path, alert: e.record.errors.full_messages.to_sentence
  end

  def merge
    source = Category.for_user(current_user).find(params[:id])
    target = Category.for_user(current_user).find(params.require(:target_id))
    raise ArgumentError, "Choose a different category outside the source subtree" if source.subtree_ids.include?(target.id)
    Category.transaction do
      ids = source.subtree_ids
      current_user.transactions.where(category_id: ids).update_all(category_id: target.id, category_locked: true, category_origin: "manual", category_reason: "Your category merge")
      current_user.transactions.where(suggested_category_id: ids).update_all(suggested_category_id: target.id)
      current_user.transaction_rules.where(category_id: ids).update_all(category_id: target.id)
      affected = current_user.budgets.where(category_id: ids + [target.id]).to_a
      raise ArgumentError, "Remove overlapping budgets before merging" if affected.size > 1
      affected.first&.update!(category: target)
      current_user.import_profiles.each do |profile|
        settings = profile.settings.deep_dup
        settings.fetch("categories", {}).transform_values! { |id| ids.include?(id.to_i) ? target.id.to_s : id }
        profile.update!(settings: settings)
      end
      # Shared categories remain intact for other users. Personal empty categories can be removed.
      source.destroy! if source.user_id == current_user.id
    end
    CashFlowClassifier.call(user: current_user)
    AutoCategorizer.call(user: current_user)
    redirect_to categories_path, notice: "Your transactions, rules and saved mappings were merged."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to categories_path, alert: e.message
  end
  private
  private :load_categories
  def category_params
    attrs = params.require(:category).permit(:name, :parent_id)
    Category.for_user(current_user).find(attrs[:parent_id]) if attrs[:parent_id].present?
    attrs
  end
end
