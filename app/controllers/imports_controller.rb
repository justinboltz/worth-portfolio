class ImportsController < ApplicationController
  before_action :require_authentication
  def new
    @profiles = current_user.import_profiles.order(:name)
    @recent_imports = current_user.import_batches.where.not(imported_at: nil).where("settings ->> 'format' = 'tiller'").order(imported_at: :desc, id: :desc).limit(10)
  end
  def create
    file = params.require(:file)
    if File.extname(file.original_filename.to_s).downcase == ".xlsx"
      data = Imports::TillerWorkbook.read(file)
      previous = current_user.import_batches.where.not(imported_at: nil).where("settings ->> 'format' = 'tiller'").order(imported_at: :desc, id: :desc).first
      @batch = current_user.import_batches.create!(csv_text: data.to_json, settings: { "format" => "tiller", "currency" => previous&.settings&.fetch("currency", "USD") || "USD", "include_duplicates" => "1", "source_filename" => File.basename(file.original_filename.to_s) })
      return redirect_to import_path(@batch)
    end
    text = file.read(5.megabytes + 1).force_encoding("UTF-8")
    raise ArgumentError, "Use a UTF-8 CSV under 5 MB" unless text.valid_encoding? && text.bytesize <= 5.megabytes
    settings = params[:profile_id].present? ? current_user.import_profiles.find(params[:profile_id]).settings : {}
    @batch = current_user.import_batches.create!(csv_text: text, settings: settings)
    redirect_to import_path(@batch)
  rescue ArgumentError, ActionController::ParameterMissing, ActiveRecord::RecordInvalid => e
    redirect_to new_import_path, alert: e.message
  end
  def show
    @batch = current_user.import_batches.find(params[:id])
    if @batch.tiller?
      @tiller = Imports::TillerPreview.new(@batch) unless @batch.imported_at
      @review_duplicates = params[:review] == "duplicates"
      preview_rows = @tiller ? @tiller.rows : []
      preview_rows = preview_rows.select { |row| row[:duplicate] && !row[:existing] && !row[:conflict] } if @review_duplicates
      preview_rows = preview_rows.select { |row| row[:conflict] } if params[:review] == "changes"
      @preview_pages = [(preview_rows.size / 50.0).ceil, 1].max
      @preview_page = params[:page].to_i.clamp(1, @preview_pages)
      @preview_rows = preview_rows.slice((@preview_page - 1) * 50, 50) || []
      return render :tiller
    end
    return redirect_to(new_import_path, notice: "Batch already imported") if @batch.imported_at
    @headers = CSV.parse(@batch.csv_text.delete_prefix("\uFEFF"), headers: true).headers.compact
    @mapping = Imports::CsvPreview::ALIASES.transform_values { |names| @headers.find { |h| names.include?(h.strip.downcase) } }.merge(@batch.settings.fetch("headers", {}))
    @preview = Imports::CsvPreview.new(@batch)
  rescue ArgumentError, CSV::MalformedCSVError => e
    @error = e.message
  ensure
    @categories = Category.for_user(current_user).includes(:parent).sort_by(&:display_name)
  end
  def update
    batch = current_user.import_batches.find(params[:id])
    raise ArgumentError, "Batch already imported" if batch.imported_at
    if batch.tiller?
      settings = params.permit(:currency, :include_duplicates, accounts: {}).to_h
      raise ArgumentError, "Invalid currency" unless Imports::TillerPreview::CURRENCIES.include?(settings["currency"])
      batch.update!(settings: batch.settings.merge(settings))
      if params[:commit_import]
        result = Imports::TillerPreview.new(batch).commit!
        return redirect_to import_path(batch), notice: "Added #{result['transactions']} transactions, #{result['balances']} daily balances and #{result['asset_valuations']} asset valuations."
      end
      return redirect_to import_path(batch)
    end
    settings = params.permit(:currency, :reverse_sign, headers: {}, categories: {}).to_h
    raise ArgumentError, "Invalid currency" unless %w[USD CAD EUR GBP].include?(settings["currency"])
    batch.update!(settings: batch.settings.merge(settings))
    if params[:commit_import]
      count = Imports::CsvPreview.new(batch).commit!(include_duplicates: Array(params[:include_duplicates]), profile_name: params[:profile_name])
      redirect_to transactions_path, notice: "Imported #{count} transactions. Balances were unchanged."
    else
      redirect_to import_path(batch)
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    redirect_to import_path(params[:id]), alert: e.message
  end
end
