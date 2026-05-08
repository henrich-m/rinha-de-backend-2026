# M07 — Submission readiness

## Goal

All submission artifacts exist and a local smoke test confirms the stack is healthy. The official score comes from the Rinha Engine after triggering a preview test via a GitHub issue.

## Tasks

1. Create `info.json` (all fields are arrays of strings except `open_to_work`):
   ```json
   {
     "participants": ["Henrich Moraes"],
     "social": ["https://github.com/henrichm"],
     "source-code-repo": "https://github.com/henrichm/rinha-2026",
     "stack": ["ruby", "falcon", "postgres", "pgvector", "pgbouncer", "nginx"],
     "open_to_work": false
   }
   ```
2. Verify `submission` branch (orphan, created in M06) has only `docker-compose.yml`, `nginx.conf`, `pgbouncer.ini`, `info.json`. Never `git add .` — always add files explicitly by name.
3. Push the pre-baked DB image: `docker push ghcr.io/henrichm/rinha-db:latest`.
4. Run a local smoke test: `docker compose up --build -d`, wait for `/ready`, send a request, `docker compose down`.
5. Trigger an official preview test: open an issue on `zanfranceschi/rinha-de-backend-2026` with `rinha/test` in the body. The Rinha Engine runs the test, posts results as a comment, and closes the issue. Check the comment for `final_score > 0`.
6. Update `CLAUDE.md`: document the submission process, branch structure, how to push the DB image, and record the first official score as a baseline.

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m07_submission_test.rb`

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

  def test_info_json_participants_is_array
    j = JSON.parse(File.read("info.json"))
    assert_instance_of Array, j["participants"]
  end

  def test_info_json_stack_is_array
    j = JSON.parse(File.read("info.json"))
    assert_instance_of Array, j["stack"]
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

  def test_stack_smoke
    # Requires docker compose up --build -d to be running
    require "net/http"
    res = Net::HTTP.get_response(URI("http://localhost:9999/ready"))
    assert_equal "200", res.code, "/ready must return 200 through the full stack"
  end
end
```
