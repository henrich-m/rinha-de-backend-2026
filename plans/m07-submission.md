# M07 — Submission readiness

## Goal

All submission artifacts exist and a local k6 preview test completes with `final_score > 0` (failure_rate < 15%, p99 < 2000ms).

## Tasks

1. Create `info.json` with `participants`, `social`, `source-code-repo`, `stack`, `open_to_work` fields.
2. Verify `submission` branch has only `docker-compose.yml`, `nginx.conf`, `pgbouncer.ini`, `info.json` (no source code).
3. Run the k6 test locally against the containerized stack and confirm `results.json` is generated.
4. Check `failure_rate < 15%` and `final_score > 0` in `results.json`.
5. Open a GitHub issue with `rinha/test` in the body to trigger an official preview test.

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m07_submission_test.rb` (k6 test must have been run and `results.json` present).

```ruby
# test/m07_submission_test.rb
require "minitest/autorun"
require "json"

class SubmissionTest < Minitest::Test
  REQUIRED_INFO_KEYS = %w[participants social source-code-repo stack].freeze
  SUBMISSION_REQUIRED_FILES = %w[docker-compose.yml nginx.conf pgbouncer.ini info.json].freeze

  def test_info_json_has_required_fields
    j = JSON.parse(File.read("info.json"))
    REQUIRED_INFO_KEYS.each do |key|
      assert j.key?(key), "info.json must have key '#{key}'"
    end
  end

  def test_submission_branch_has_required_files
    SUBMISSION_REQUIRED_FILES.each do |file|
      system("git show submission:#{file} > /dev/null 2>&1")
      assert $?.success?, "#{file} must exist on the submission branch"
    end
  end

  def test_submission_branch_has_no_source_code
    system("git show submission:src/server.rb > /dev/null 2>&1")
    refute $?.success?, "src/server.rb must NOT exist on the submission branch"
  end

  def test_results_json_exists
    assert File.exist?("results.json"), "results.json must exist (run k6 first)"
  end

  def test_failure_rate_below_threshold
    summary = k6_summary
    skip "no k6 summary found in results.json" unless summary
    rate = summary.dig("metrics", "http_req_failed", "values", "rate") || 0.0
    assert_operator rate, :<, 0.15, "failure rate must be below 15%"
  end

  private

  def k6_summary
    return @k6_summary if defined?(@k6_summary)
    lines = File.readlines("results.json")
    @k6_summary = lines.lazy
      .map { JSON.parse(_1) rescue nil }
      .find { _1&.dig("type") == "summary" }
  end
end
```
