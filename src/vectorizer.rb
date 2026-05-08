# frozen_string_literal: true

require "json"
require "time"

class Vectorizer
  def initialize(normalization_path, mcc_risk_path)
    norm = JSON.parse(File.read(normalization_path))
    @max_amount         = norm["max_amount"].to_f
    @max_installments   = norm["max_installments"].to_f
    @amount_vs_avg_ratio = norm["amount_vs_avg_ratio"].to_f
    @max_minutes        = norm["max_minutes"].to_f
    @max_km             = norm["max_km"].to_f
    @max_tx_count_24h   = norm["max_tx_count_24h"].to_f
    @max_merchant_avg   = norm["max_merchant_avg_amount"].to_f

    @mcc_risk = JSON.parse(File.read(mcc_risk_path)).freeze
  end

  def vectorize(payload)
    tx       = payload["transaction"]
    customer = payload["customer"]
    merchant = payload["merchant"]
    terminal = payload["terminal"]
    last_tx  = payload["last_transaction"]

    amount      = tx["amount"].to_f
    t           = Time.iso8601(tx["requested_at"]).utc
    avg_amount  = customer["avg_amount"].to_f

    if last_tx
      minutes_since = (t - Time.iso8601(last_tx["timestamp"])) / 60.0
      dim5 = clamp(minutes_since / @max_minutes)
      dim6 = clamp(last_tx["km_from_current"].to_f / @max_km)
    else
      dim5 = -1.0
      dim6 = -1.0
    end

    [
      clamp(amount / @max_amount),
      clamp(tx["installments"].to_f / @max_installments),
      clamp((amount / avg_amount) / @amount_vs_avg_ratio),
      t.hour / 23.0,
      (t.wday + 6) % 7 / 6.0,
      dim5,
      dim6,
      clamp(terminal["km_from_home"].to_f / @max_km),
      clamp(customer["tx_count_24h"].to_f / @max_tx_count_24h),
      terminal["is_online"] ? 1.0 : 0.0,
      terminal["card_present"] ? 1.0 : 0.0,
      customer["known_merchants"].include?(merchant["id"]) ? 0.0 : 1.0,
      @mcc_risk.fetch(merchant["mcc"], 0.5),
      clamp(merchant["avg_amount"].to_f / @max_merchant_avg)
    ]
  end

  private

  def clamp(x)
    x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)
  end
end
